import Foundation
import CoreGraphics
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - 任务状态

enum TaskStage: String, Sendable {
    case idle = "就绪"
    case extracting = "解压中"
    case ocr = "OCR 识别"
    case transcribing = "语音转写"
    case extractingAudio = "提取音频"
    case translating = "翻译中"
    case rendering = "渲染中"
    case packing = "打包中"
    case writingSubtitle = "生成字幕"
    case completed = "已完成"
    case failed = "失败"
}

struct TaskProgress: Sendable {
    let stage: TaskStage
    let currentFile: Int
    let totalFiles: Int
    let fileName: String
    let message: String
}

// MARK: - 单文件任务状态

enum FileTaskStatus: Sendable {
    case pending
    case processing
    case completed(URL)
    case failed(String)

    var label: String {
        switch self {
        case .pending: return "等待中"
        case .processing: return "处理中"
        case .completed: return "完成"
        case .failed: return "失败"
        }
    }
}

struct FileTask: Identifiable, Sendable {
    let id: UUID
    let inputURL: URL
    var status: FileTaskStatus
    var progress: TaskProgress?
    var outputURL: URL?
    var errorMessage: String?

    init(inputURL: URL) {
        self.id = UUID()
        self.inputURL = inputURL
        self.status = .pending
    }
}

// MARK: - 日志条目

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let level: Level
    let message: String

    enum Level: Sendable {
        case info, success, warning, error
    }
}

// MARK: - Translator（主协调器）

@MainActor
final class ComicTranslator: ObservableObject {
    @Published var isProcessing = false
    @Published var fileTasks: [FileTask] = []
    @Published var currentBatchIndex: Int = 0
    @Published var logs: [LogEntry] = []
    @Published var batchCompleted: Bool = false

    private let ocrEngine = OCREngine()
    private let cache = TranslationCache()
    private let speechTranscriber = SpeechTranscriber()
    private var currentTask: Task<Void, Never>?

    private static let maxLogEntries = 2000
    nonisolated static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif", "webp", "heic"
    ]

    // MARK: - 计算属性

    var overallProgress: (current: Int, total: Int) {
        let total = fileTasks.count
        let done = fileTasks.reduce(0) { count, task in
            switch task.status {
            case .completed, .failed: return count + 1
            default: return count
            }
        }
        return (done, total)
    }

    var activeTask: FileTask? {
        fileTasks.first { if case .processing = $0.status { return true } else { return false } }
    }

    var lastCompletedOutput: URL? {
        fileTasks.reversed().first { if case .completed = $0.status { return true } else { return false } }
            .flatMap { if case .completed(let url) = $0.status { return url } else { return nil } }
    }

    var anyFailed: Bool {
        fileTasks.contains { if case .failed = $0.status { return true } else { return false } }
    }

    // MARK: - 任务管理

    func addFiles(_ urls: [URL]) {
        guard !isProcessing else { return }
        let existing = Set(fileTasks.map(\.inputURL.path))
        let newTasks = urls
            .filter { !existing.contains($0.path) }
            .map { FileTask(inputURL: $0) }
        fileTasks.append(contentsOf: newTasks)
        batchCompleted = false
    }

    func removeFile(id: UUID) {
        guard !isProcessing else { return }
        fileTasks.removeAll { $0.id == id }
    }

    func clearFiles() {
        guard !isProcessing else { return }
        fileTasks.removeAll()
        batchCompleted = false
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isProcessing = false
        addLog(.warning, "⚠️ 已取消")
    }

    // MARK: - 批量翻译

    func translateBatch(settings: AppSettings) {
        guard !isProcessing, !fileTasks.isEmpty else { return }

        isProcessing = true
        batchCompleted = false
        logs.removeAll()

        // 重置所有任务状态
        for i in fileTasks.indices {
            fileTasks[i].status = .pending
            fileTasks[i].progress = nil
            fileTasks[i].outputURL = nil
            fileTasks[i].errorMessage = nil
        }

        currentTask = Task { @MainActor in
            defer {
                self.isProcessing = false
                self.batchCompleted = true
            }

            let total = self.fileTasks.count
            let batchStart = CFAbsoluteTimeGetCurrent()
            self.addLog(.info, "🚀 开始批量翻译 \(total) 个文件")

            // 测试 API 连接
            let connectStart = CFAbsoluteTimeGetCurrent()
            let apiConfig = TranslationConfig(
                endpoint: settings.apiEndpoint,
                apiKey: settings.apiKey,
                modelID: settings.modelID,
                temperature: settings.temperature,
                customPromptTemplate: settings.customPromptTemplate,
                domainInstruction: settings.domain.systemInstruction(customPrompt: settings.customDomainPrompt)
            )
            let api = makeTranslationAPI(format: settings.apiFormat, config: apiConfig)

            guard await api.testConnection() else {
                self.addLog(.error, "❌ 无法连接到翻译 API: \(settings.apiEndpoint)")
                for i in self.fileTasks.indices {
                    self.fileTasks[i].status = .failed("API 连接失败")
                    self.fileTasks[i].errorMessage = "API 连接失败"
                }
                return
            }
            self.addLog(.success, "✅ API 连接成功 (\(settings.apiFormat.displayName)) [\(self.formatElapsed(CFAbsoluteTimeGetCurrent() - connectStart))]")

            if settings.domain != .general {
                self.addLog(.info, "🎯 领域: \(settings.domain.displayName)")
            }

            self.addLog(.info, "─────────────────────────────────────")

            // 逐文件处理
            for idx in 0..<total {
                guard !Task.isCancelled else { break }

                let fileTask = self.fileTasks[idx]
                self.currentBatchIndex = idx
                self.fileTasks[idx].status = .processing
                let fileStart = CFAbsoluteTimeGetCurrent()
                self.addLog(.info, "📂 [\(idx + 1)/\(total)] \(fileTask.inputURL.lastPathComponent)")

                do {
                    let output = try await self.processFile(
                        inputURL: fileTask.inputURL,
                        settings: settings,
                        api: api,
                        progressUpdate: { @Sendable [weak self] progress in
                            Task { @MainActor [weak self] in
                                self?.fileTasks[idx].progress = progress
                            }
                        }
                    )
                    self.fileTasks[idx].status = .completed(output)
                    self.fileTasks[idx].outputURL = output
                    let elapsed = self.formatElapsed(CFAbsoluteTimeGetCurrent() - fileStart)
                    self.addLog(.success, "✅ [\(idx + 1)/\(total)] \(output.lastPathComponent) [\(elapsed)]")
                } catch {
                    if Task.isCancelled {
                        self.fileTasks[idx].status = .failed("已取消")
                        break
                    }
                    let msg = error.localizedDescription
                    self.fileTasks[idx].status = .failed(msg)
                    self.fileTasks[idx].errorMessage = msg
                    let elapsed = self.formatElapsed(CFAbsoluteTimeGetCurrent() - fileStart)
                    self.addLog(.error, "❌ [\(idx + 1)/\(total)] \(msg) [\(elapsed)]")
                }
            }

            self.addLog(.info, "─────────────────────────────────────")
            let successCount = self.fileTasks.filter { if case .completed = $0.status { return true } else { return false } }.count
            let failCount = self.fileTasks.filter { if case .failed = $0.status { return true } else { return false } }.count
            let batchElapsed = self.formatElapsed(CFAbsoluteTimeGetCurrent() - batchStart)
            self.addLog(.info, "📊 完成: \(successCount) 成功, \(failCount) 失败 | 总耗时: \(batchElapsed)")
        }
    }

    // MARK: - 文件分发（根据类型走不同处理流水线）

    private func processFile(
        inputURL: URL,
        settings: AppSettings,
        api: TranslationAPI,
        progressUpdate: @escaping @Sendable (TaskProgress) -> Void
    ) async throws -> URL {
        let ext = inputURL.pathExtension.lowercased()
        if SpeechTranscriber.audioExtensions.contains(ext) || SpeechTranscriber.videoExtensions.contains(ext) {
            return try await processMedia(
                inputURL: inputURL,
                settings: settings,
                api: api,
                progressUpdate: progressUpdate
            )
        }
        if ext == "pdf" {
            return try await processPDF(
                inputURL: inputURL,
                settings: settings,
                api: api,
                progressUpdate: progressUpdate
            )
        }
        return try await processArchive(
            inputURL: inputURL,
            settings: settings,
            api: api,
            progressUpdate: progressUpdate
        )
    }

    // MARK: - 音视频转写 + 翻译 → SRT

    private func processMedia(
        inputURL: URL,
        settings: AppSettings,
        api: TranslationAPI,
        progressUpdate: @escaping @Sendable (TaskProgress) -> Void
    ) async throws -> URL {
        let mediaStart = CFAbsoluteTimeGetCurrent()
        let fileName = inputURL.lastPathComponent
        let ext = inputURL.pathExtension.lowercased()
        let isVideo = SpeechTranscriber.videoExtensions.contains(ext)

        // 1. 请求权限
        let auth = await SpeechTranscriber.requestAuthorization()
        guard auth == .authorized else {
            throw SpeechTranscribeError.notAuthorized
        }

        // 2. 启动转写（如果是视频会内部先抽音频）
        let stepStart = CFAbsoluteTimeGetCurrent()
        if isVideo {
            progressUpdate(TaskProgress(stage: .extractingAudio, currentFile: 0, totalFiles: 1, fileName: fileName, message: "提取音频轨"))
        }

        let langCode = settings.sourceLang  // "auto" / "ja" / "en" ...
        let resolvedLocale = SpeechTranscriber.resolveLocale(code: langCode, fileName: fileName)
        addLog(.info, "   🗣️ 识别语言: \(resolvedLocale.identifier) (源设置: \(langCode))")
        progressUpdate(TaskProgress(stage: .transcribing, currentFile: 0, totalFiles: 1, fileName: fileName, message: "识别中 (\(resolvedLocale.identifier))"))

        let segments = try await speechTranscriber.transcribe(
            fileURL: inputURL,
            languageCode: langCode,
            progress: { p in
                Task { @MainActor in
                    progressUpdate(TaskProgress(
                        stage: .transcribing,
                        currentFile: Int(p * 100),
                        totalFiles: 100,
                        fileName: fileName,
                        message: String(format: "识别中 %.0f%%", p * 100)
                    ))
                }
            }
        )
        let transcribeTime = CFAbsoluteTimeGetCurrent() - stepStart
        addLog(.info, "   🎙️ 识别完成：\(segments.count) 段 [\(formatElapsed(transcribeTime))]")

        guard !segments.isEmpty else {
            addLog(.warning, "   ⚠️ 未识别到语音。请确认源语言设置与音频实际语言一致")
            throw TranslatorError.noTranscript
        }

        try Task.checkCancellation()

        // 3. 批量翻译每段文字
        progressUpdate(TaskProgress(
            stage: .translating, currentFile: 0, totalFiles: segments.count,
            fileName: fileName, message: "翻译 \(segments.count) 段字幕"
        ))

        let translateStart = CFAbsoluteTimeGetCurrent()
        let texts = segments.map(\.text)
        let translations = await translateTextsBatch(
            texts: texts,
            from: settings.sourceLang,
            to: settings.targetLang,
            api: api,
            cache: cache,
            concurrency: settings.concurrency,
            domainKey: settings.domain.rawValue
        )
        let translateTime = CFAbsoluteTimeGetCurrent() - translateStart

        try Task.checkCancellation()

        // 4. 写入字幕文件
        progressUpdate(TaskProgress(
            stage: .writingSubtitle, currentFile: segments.count, totalFiles: segments.count,
            fileName: fileName, message: "生成字幕"
        ))

        let writeStart = CFAbsoluteTimeGetCurrent()
        let outputURL = generateSubtitleOutputURL(from: inputURL, kind: settings.subtitleFormat, bilingual: settings.subtitleBilingual)

        try await Task.detached(priority: .userInitiated) { [outputURL, segments, translations, settings] in
            switch settings.subtitleFormat {
            case .srt:
                if settings.subtitleBilingual {
                    try SubtitleWriter.writeBilingualSRT(segments: segments, translations: translations, to: outputURL)
                } else {
                    try SubtitleWriter.writeTranslationSRT(segments: segments, translations: translations, to: outputURL)
                }
            case .txt:
                try SubtitleWriter.writeTXT(segments: segments, translations: translations, to: outputURL, bilingual: settings.subtitleBilingual)
            }
        }.value
        let writeTime = CFAbsoluteTimeGetCurrent() - writeStart

        // 5. 统计
        let totalTime = CFAbsoluteTimeGetCurrent() - mediaStart
        addLog(.info, "   ⏱️ 转写: \(formatElapsed(transcribeTime)) | 翻译: \(formatElapsed(translateTime)) | 写入: \(formatElapsed(writeTime))")
        addLog(.info, "   📊 \(segments.count) 段字幕 | 总耗时: \(formatElapsed(totalTime))")

        return outputURL
    }

    private func generateSubtitleOutputURL(from inputURL: URL, kind: SubtitleFormat, bilingual: Bool) -> URL {
        let dir = inputURL.deletingLastPathComponent()
        let baseName = (inputURL.lastPathComponent as NSString).deletingPathExtension
        let suffix = bilingual ? ".中文-双语" : ".中文"
        var finalURL = dir.appendingPathComponent(baseName + suffix + "." + kind.fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: finalURL.path) {
            finalURL = dir.appendingPathComponent("\(baseName)\(suffix)-\(counter).\(kind.fileExtension)")
            counter += 1
        }
        return finalURL
    }

    // MARK: - PDF 处理流水线

    private func processPDF(
        inputURL: URL,
        settings: AppSettings,
        api: TranslationAPI,
        progressUpdate: @escaping @Sendable (TaskProgress) -> Void
    ) async throws -> URL {
        let pdfStart = CFAbsoluteTimeGetCurrent()
        let outputURL = generatePDFOutputURL(from: inputURL)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicTranslatorPDF_\(UUID().uuidString)", isDirectory: true)
        let pageDir = tempDir.appendingPathComponent("pages")
        let outputDir = tempDir.appendingPathComponent("out")

        try FileManager.default.createDirectory(at: pageDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: tempDir) }

        var stepStart = CFAbsoluteTimeGetCurrent()
        progressUpdate(TaskProgress(
            stage: .extracting,
            currentFile: 0,
            totalFiles: 1,
            fileName: inputURL.lastPathComponent,
            message: "渲染 PDF 页面"
        ))

        let pdfRenderConcurrency = max(1, settings.taskConcurrency)
        if pdfRenderConcurrency > 1 {
            addLog(.info, "   ⚙️ PDF 拆页并发: \(pdfRenderConcurrency)")
        }
        let pages = try await Task.detached(priority: .userInitiated) { [inputURL, pageDir, pdfRenderConcurrency] in
            try await PDFHandler.renderPages(from: inputURL, to: pageDir, concurrency: pdfRenderConcurrency)
        }.value
        addLog(.info, "   📄 PDF 渲染完成：\(pages.count) 页 [\(formatElapsed(CFAbsoluteTimeGetCurrent() - stepStart))]")

        try Task.checkCancellation()

        let sourceLangOpt = LanguageOption.named(settings.sourceLang) ?? LanguageOption.auto
        let ocrLangs = sourceLangOpt.ocrLanguages

        let pageFiles = pages.map(\.relativePath)
        let stats = try await processImages(
            imageFiles: pageFiles,
            extractDir: pageDir,
            outputDir: outputDir,
            ocrLangs: ocrLangs,
            settings: settings,
            api: api,
            progressUpdate: progressUpdate
        )

        try Task.checkCancellation()

        stepStart = CFAbsoluteTimeGetCurrent()
        progressUpdate(TaskProgress(
            stage: .packing,
            currentFile: pages.count,
            totalFiles: pages.count,
            fileName: outputURL.lastPathComponent,
            message: "生成 PDF"
        ))

        try await Task.detached(priority: .userInitiated) { [pages, outputDir, outputURL] in
            try PDFHandler.createPDF(from: pages, imageDirectory: outputDir, to: outputURL)
        }.value
        let packTime = CFAbsoluteTimeGetCurrent() - stepStart

        let totalTime = CFAbsoluteTimeGetCurrent() - pdfStart
        addLog(.info, "   ⏱️ OCR: \(formatElapsed(stats.ocrTime)) | 翻译: \(formatElapsed(stats.translateTime)) | 渲染: \(formatElapsed(stats.renderTime)) | 生成 PDF: \(formatElapsed(packTime))")
        addLog(.info, "   📊 \(stats.translated) 已翻译, \(stats.skipped) 无文字, \(stats.failed) 失败 | 总耗时: \(formatElapsed(totalTime))")

        return outputURL
    }

    // MARK: - 单文件处理流水线（压缩包/漫画）

    private func processArchive(
        inputURL: URL,
        settings: AppSettings,
        api: TranslationAPI,
        progressUpdate: @escaping @Sendable (TaskProgress) -> Void
    ) async throws -> URL {
        let archiveStart = CFAbsoluteTimeGetCurrent()

        // 1. 识别格式
        guard let format = ArchiveFormat.from(fileName: inputURL.lastPathComponent) else {
            throw TranslatorError.unsupportedFormat(inputURL.pathExtension)
        }

        // 2. 输出路径
        let outputFormat = resolveOutputFormat(settings: settings, inputFormat: format)
        let outputURL = generateOutputURL(from: inputURL, outputFormat: outputFormat)

        // 3. 临时目录
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicTranslator_\(UUID().uuidString)", isDirectory: true)
        let extractDir = tempDir.appendingPathComponent("in")
        let outputDir = tempDir.appendingPathComponent("out")

        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 4. 解压（后台）
        var stepStart = CFAbsoluteTimeGetCurrent()
        progressUpdate(TaskProgress(stage: .extracting, currentFile: 0, totalFiles: 1, fileName: inputURL.lastPathComponent, message: "解压中..."))
        try await Task.detached(priority: .userInitiated) {
            try ArchiveHandler.extract(inputURL, format: format, to: extractDir)
        }.value
        addLog(.info, "   📦 解压完成 [\(formatElapsed(CFAbsoluteTimeGetCurrent() - stepStart))]")

        try Task.checkCancellation()

        // 5. 收集图片（后台）
        let imageFiles = try await Task.detached(priority: .userInitiated) { [extractDir] in
            try Self.collectImageFiles(in: extractDir)
        }.value

        guard !imageFiles.isEmpty else {
            throw TranslatorError.noImages
        }
        addLog(.info, "   🖼️ 发现 \(imageFiles.count) 张图片")

        // 6. OCR 语言
        let sourceLangOpt = LanguageOption.named(settings.sourceLang) ?? LanguageOption.auto
        let ocrLangs = sourceLangOpt.ocrLanguages

        // 7. 逐图处理
        let stats = try await processImages(
            imageFiles: imageFiles,
            extractDir: extractDir,
            outputDir: outputDir,
            ocrLangs: ocrLangs,
            settings: settings,
            api: api,
            progressUpdate: progressUpdate
        )

        try Task.checkCancellation()

        // 8. 复制非图片文件（后台）
        await Task.detached(priority: .userInitiated) { [extractDir, outputDir] in
            Self.copyNonImageFiles(from: extractDir, to: outputDir)
        }.value

        // 9. 打包（后台）
        stepStart = CFAbsoluteTimeGetCurrent()
        progressUpdate(TaskProgress(stage: .packing, currentFile: imageFiles.count, totalFiles: imageFiles.count, fileName: outputURL.lastPathComponent, message: "打包"))
        try await Task.detached(priority: .userInitiated) { [outputDir, outputURL, outputFormat] in
            try ArchiveHandler.create(from: outputDir, to: outputURL, format: outputFormat)
        }.value
        let packTime = CFAbsoluteTimeGetCurrent() - stepStart

        // 10. 耗时统计
        let totalTime = CFAbsoluteTimeGetCurrent() - archiveStart
        addLog(.info, "   ⏱️ OCR: \(formatElapsed(stats.ocrTime)) | 翻译: \(formatElapsed(stats.translateTime)) | 渲染: \(formatElapsed(stats.renderTime)) | 打包: \(formatElapsed(packTime))")
        addLog(.info, "   📊 \(stats.translated) 已翻译, \(stats.skipped) 无文字, \(stats.failed) 失败 | 总耗时: \(formatElapsed(totalTime))")

        return outputURL
    }

    // MARK: - 图片处理

    private struct ProcessingStats: Sendable {
        var translated = 0
        var skipped = 0
        var failed = 0
        var ocrTime: Double = 0
        var translateTime: Double = 0
        var renderTime: Double = 0

        mutating func merge(_ other: ProcessingStats) {
            translated += other.translated
            skipped += other.skipped
            failed += other.failed
            ocrTime += other.ocrTime
            translateTime += other.translateTime
            renderTime += other.renderTime
        }
    }

    private struct ImageProcessingConfig: Sendable {
        let sourceLang: String
        let targetLang: String
        let domainKey: String
        let imageConcurrency: Int
        let apiConcurrencyPerImage: Int
    }

    private actor ImageProgressReporter {
        private let totalFiles: Int
        private let progressUpdate: @Sendable (TaskProgress) -> Void
        private var lastProgressTime: CFAbsoluteTime = 0

        init(totalFiles: Int, progressUpdate: @escaping @Sendable (TaskProgress) -> Void) {
            self.totalFiles = totalFiles
            self.progressUpdate = progressUpdate
        }

        func report(stage: TaskStage, index: Int, fileName: String, message: String) {
            let now = CFAbsoluteTimeGetCurrent()
            let shouldReport = index == 0 || (now - lastProgressTime) > 0.15 || index == totalFiles - 1
            guard shouldReport else { return }
            lastProgressTime = now
            progressUpdate(TaskProgress(
                stage: stage,
                currentFile: index + 1,
                totalFiles: totalFiles,
                fileName: fileName,
                message: message
            ))
        }
    }

    private func processImages(
        imageFiles: [String],
        extractDir: URL,
        outputDir: URL,
        ocrLangs: [String],
        settings: AppSettings,
        api: TranslationAPI,
        progressUpdate: @escaping @Sendable (TaskProgress) -> Void
    ) async throws -> ProcessingStats {
        var stats = ProcessingStats()

        let requestedImageConcurrency = max(1, settings.taskConcurrency)
        let imageConcurrency = min(requestedImageConcurrency, max(1, imageFiles.count))
        let apiConcurrencyPerImage = max(1, settings.concurrency / max(1, imageConcurrency))
        let config = ImageProcessingConfig(
            sourceLang: settings.sourceLang,
            targetLang: settings.targetLang,
            domainKey: settings.domain.rawValue,
            imageConcurrency: imageConcurrency,
            apiConcurrencyPerImage: apiConcurrencyPerImage
        )

        if config.imageConcurrency > 1 {
            addLog(.info, "   ⚙️ 页面并发: \(config.imageConcurrency) | 每页 API 并发: \(config.apiConcurrencyPerImage)")
        }

        let imageSemaphore = AsyncSemaphore(value: config.imageConcurrency)
        let progressReporter = ImageProgressReporter(totalFiles: imageFiles.count, progressUpdate: progressUpdate)

        try await withThrowingTaskGroup(of: ProcessingStats.self) { group in
            for (index, relativePath) in imageFiles.enumerated() {
                group.addTask { [extractDir, outputDir, ocrLangs, api, cache, ocrEngine, config, imageSemaphore, progressReporter] in
                    await imageSemaphore.wait()
                    do {
                        let imageStats = try await Self.processImage(
                            index: index,
                            relativePath: relativePath,
                            extractDir: extractDir,
                            outputDir: outputDir,
                            ocrLangs: ocrLangs,
                            config: config,
                            api: api,
                            cache: cache,
                            ocrEngine: ocrEngine,
                            progressReporter: progressReporter
                        )
                        await imageSemaphore.signal()
                        return imageStats
                    } catch {
                        await imageSemaphore.signal()
                        throw error
                    }
                }
            }

            for try await imageStats in group {
                stats.merge(imageStats)
            }
        }

        return stats
    }

    nonisolated private static func processImage(
        index: Int,
        relativePath: String,
        extractDir: URL,
        outputDir: URL,
        ocrLangs: [String],
        config: ImageProcessingConfig,
        api: TranslationAPI,
        cache: TranslationCache,
        ocrEngine: OCREngine,
        progressReporter: ImageProgressReporter
    ) async throws -> ProcessingStats {
        try Task.checkCancellation()

        var stats = ProcessingStats()
        let inputURL = extractDir.appendingPathComponent(relativePath)
        let outputURL = outputDir.appendingPathComponent(relativePath)
        let outputParent = outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: outputParent, withIntermediateDirectories: true)

        await progressReporter.report(stage: .ocr, index: index, fileName: relativePath, message: "OCR 识别")

        // 加载图片（后台）
        let cgImageOpt: CGImage? = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return img
        }.value

        guard let cgImage = cgImageOpt else {
            Self.safeCopy(from: inputURL, to: outputURL)
            stats.failed += 1
            return stats
        }

        // OCR
        var stepStart = CFAbsoluteTimeGetCurrent()
        let ocrResults: [OCRResult]
        do {
            ocrResults = try await ocrEngine.recognize(image: cgImage, languages: ocrLangs)
        } catch {
            Self.safeCopy(from: inputURL, to: outputURL)
            stats.failed += 1
            return stats
        }
        stats.ocrTime += CFAbsoluteTimeGetCurrent() - stepStart

        let validOCR = ocrResults.filter { $0.boundingBox.width > 0.001 && $0.boundingBox.height > 0.001 }

        if validOCR.isEmpty {
            Self.safeCopy(from: inputURL, to: outputURL)
            stats.skipped += 1
            return stats
        }

        let textBlocks = validOCR.map { TextBlock(from: $0) }
        let regions = RegionSegmenter().segment(blocks: textBlocks)
        let textMerger = TextMerger()
        let mergedBlocks = regions.flatMap { textMerger.merge(blocks: $0.blocks) }

        if mergedBlocks.isEmpty {
            Self.safeCopy(from: inputURL, to: outputURL)
            stats.skipped += 1
            return stats
        }

        await progressReporter.report(stage: .translating, index: index, fileName: relativePath, message: "翻译 \(mergedBlocks.count) 段")

        stepStart = CFAbsoluteTimeGetCurrent()
        let texts = mergedBlocks.map(\.text)
        let translations = await translateTextsBatch(
            texts: texts,
            from: config.sourceLang,
            to: config.targetLang,
            api: api,
            cache: cache,
            concurrency: config.apiConcurrencyPerImage,
            domainKey: config.domainKey
        )
        stats.translateTime += CFAbsoluteTimeGetCurrent() - stepStart

        try Task.checkCancellation()

        await progressReporter.report(stage: .rendering, index: index, fileName: relativePath, message: "渲染")

        stepStart = CFAbsoluteTimeGetCurrent()
        let renderSuccess: Bool = await Task.detached(priority: .userInitiated) {
            guard let rendered = ImageRenderer.renderTranslated(
                original: cgImage,
                textBlocks: mergedBlocks,
                translations: translations
            ) else { return false }

            let imgFormat = ImageRenderer.imageFormat(for: outputURL)
            do {
                try ImageRenderer.saveImage(rendered, to: outputURL, format: imgFormat)
                return true
            } catch {
                return false
            }
        }.value
        stats.renderTime += CFAbsoluteTimeGetCurrent() - stepStart

        if renderSuccess {
            stats.translated += 1
        } else {
            Self.safeCopy(from: inputURL, to: outputURL)
            stats.failed += 1
        }

        return stats
    }

    // MARK: - 辅助方法（nonisolated，可在 detached Task 中调用）

    nonisolated static func collectImageFiles(in directory: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else {
            throw TranslatorError.cannotEnumerate
        }
        var files: [String] = []
        while let file = enumerator.nextObject() as? String {
            let ext = (file as NSString).pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                files.append(file)
            }
        }
        files.sort()
        return files
    }

    nonisolated static func copyNonImageFiles(from sourceDir: URL, to destDir: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: sourceDir.path) else { return }
        while let file = enumerator.nextObject() as? String {
            let ext = (file as NSString).pathExtension.lowercased()
            guard !imageExtensions.contains(ext) else { continue }
            let src = sourceDir.appendingPathComponent(file)
            let dst = destDir.appendingPathComponent(file)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue {
                try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dst.path) {
                    try? fm.removeItem(at: dst)
                }
                try? fm.copyItem(at: src, to: dst)
            }
        }
    }

    /// 安全复制（目标已存在时先删除，避免 copyItem 失败）
    nonisolated static func safeCopy(from src: URL, to dst: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) {
            try? fm.removeItem(at: dst)
        }
        try? fm.copyItem(at: src, to: dst)
    }

    func addLog(_ level: LogEntry.Level, _ message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        logs.append(entry)
        if logs.count > Self.maxLogEntries {
            logs.removeFirst(logs.count - Self.maxLogEntries)
        }
    }

    /// 格式化耗时为可读字符串
    func formatElapsed(_ seconds: Double) -> String {
        if seconds < 1 {
            return String(format: "%.0fms", seconds * 1000)
        } else if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            let min = Int(seconds) / 60
            let sec = seconds - Double(min * 60)
            return String(format: "%dm%.1fs", min, sec)
        }
    }

    private func resolveOutputFormat(settings: AppSettings, inputFormat: ArchiveFormat) -> ArchiveFormat {
        switch settings.outputFormat {
        case .sameAsInput:
            switch inputFormat {
            case .rar: return .zip
            case .cbr: return .cbz
            default: return inputFormat
            }
        case .zip: return .zip
        case .cbz: return .cbz
        }
    }

    private func generateOutputURL(from inputURL: URL, outputFormat: ArchiveFormat) -> URL {
        let dir = inputURL.deletingLastPathComponent()
        let outputName = translatedOutputBaseName(from: inputURL)

        // 避免覆盖已存在文件
        var finalURL = dir.appendingPathComponent(outputName + "." + outputFormat.fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: finalURL.path) {
            finalURL = dir.appendingPathComponent("\(outputName)-\(counter).\(outputFormat.fileExtension)")
            counter += 1
        }
        return finalURL
    }

    private func generatePDFOutputURL(from inputURL: URL) -> URL {
        let dir = inputURL.deletingLastPathComponent()
        let outputName = translatedOutputBaseName(from: inputURL)

        var finalURL = dir.appendingPathComponent(outputName + ".pdf")
        var counter = 2
        while FileManager.default.fileExists(atPath: finalURL.path) {
            finalURL = dir.appendingPathComponent("\(outputName)-\(counter).pdf")
            counter += 1
        }
        return finalURL
    }

    private func translatedOutputBaseName(from inputURL: URL) -> String {
        let fileName = inputURL.lastPathComponent
        let lower = fileName.lowercased()

        let baseName: String
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tar.xz") {
            let withoutLast = (fileName as NSString).deletingPathExtension
            baseName = (withoutLast as NSString).deletingPathExtension
        } else {
            baseName = (fileName as NSString).deletingPathExtension
        }

        // 按长度降序（避免 "Japanese" 被 "JP" 先匹配），长匹配优先
        let patterns = [
            "イタリア翻訳", "イタリア語",
            "Japanese", "japanese", "Italian", "italian",
            "Korean", "korean", "French", "french",
            "Deutsch", "deutsch", "German", "german",
            "English", "english",
            "日文", "日语", "英文", "英语", "韩文", "韩语",
            "[JP]", "[jp]", "[JA]", "[ja]", "(JP)", "(jp)", "(JA)", "(ja)"
        ]

        var outputName = baseName
        var replaced = false

        // 避免给已经是 "中文" 的文件再加 "-中文"
        if baseName.contains("中文") || baseName.contains("Chinese") || baseName.contains("chinese") {
            replaced = true  // 已是中文版，不重复添加
        } else {
            for p in patterns {
                if baseName.contains(p) {
                    outputName = baseName.replacingOccurrences(of: p, with: "中文")
                    replaced = true
                    break
                }
            }
            if !replaced {
                outputName = baseName + "-中文"
            }
        }
        return outputName
    }
}

// MARK: - 错误类型

enum TranslatorError: Error, LocalizedError {
    case unsupportedFormat(String)
    case noImages
    case noTranscript
    case cannotEnumerate

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return "不支持的格式: \(ext)"
        case .noImages: return "压缩包中无图片文件"
        case .noTranscript: return "未识别到语音内容。请检查：1) 源语言设置是否与音频语言一致 2) 音频是否有清晰人声"
        case .cannotEnumerate: return "无法遍历文件目录"
        }
    }
}
