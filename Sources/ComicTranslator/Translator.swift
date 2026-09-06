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
        guard let currentTask else { return }
        currentTask.cancel()
        addLog(.warning, "⏹️ 正在取消，等待已启动的任务停止…")
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
                let wasCancelled = Task.isCancelled
                self.isProcessing = false
                self.batchCompleted = !wasCancelled
                self.currentTask = nil
                if wasCancelled {
                    self.addLog(.warning, "⏹️ 取消完成，所有批次已停止")
                }
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
            concurrency: settings.batchConcurrency,
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
        var batchRequestCount = 0
        var fallbackCount = 0
        var untranslatedBlocks = 0

        mutating func merge(_ other: ProcessingStats) {
            translated += other.translated
            skipped += other.skipped
            failed += other.failed
            ocrTime += other.ocrTime
            translateTime += other.translateTime
            renderTime += other.renderTime
            batchRequestCount += other.batchRequestCount
            fallbackCount += other.fallbackCount
            untranslatedBlocks += other.untranslatedBlocks
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

        if settings.batchTranslationEnabled {
            return try await processImagesBatched(
                imageFiles: imageFiles,
                extractDir: extractDir,
                outputDir: outputDir,
                ocrLangs: ocrLangs,
                settings: settings,
                api: api,
                progressUpdate: progressUpdate
            )
        }

        let requestedImageConcurrency = max(1, settings.taskConcurrency)
        let imageConcurrency = min(requestedImageConcurrency, max(1, imageFiles.count))
        let apiConcurrencyPerImage = max(1, settings.batchConcurrency / max(1, imageConcurrency))
        let config = ImageProcessingConfig(
            sourceLang: settings.sourceLang,
            targetLang: settings.targetLang,
            domainKey: settings.domain.rawValue,
            imageConcurrency: imageConcurrency,
            apiConcurrencyPerImage: apiConcurrencyPerImage
        )

        if config.imageConcurrency > 1 {
            addLog(.info, "   ⚙️ 页面处理并发: \(config.imageConcurrency) | 翻译并发: \(settings.batchConcurrency)（按页分配）")
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

    // MARK: - 跨页批量翻译（settings.batchTranslationEnabled == true）

    private struct BatchProcessingConfig: Sendable {
        let sourceLang: String
        let targetLang: String
        let domainKey: String
        let batchConcurrency: Int
        let maxPagesPerBatch: Int
    }

    typealias BatchLogHandler = @Sendable (LogEntry.Level, String) -> Void

    private actor BatchExecutionTracker {
        private var active = 0

        func begin() -> Int {
            active += 1
            return active
        }

        func end() -> Int {
            active = max(0, active - 1)
            return active
        }
    }

    private struct PreparedPage: Sendable {
        let pageIndex: Int
        let relativePath: String
        let image: SendableImage
        let mergedBlocks: [MergedTextBlock]
    }

    private struct PrepareResult: Sendable {
        let page: PreparedPage?
        let stats: ProcessingStats
    }

    /// 供纯 helper 测试使用的块数据：pageIndex + blockIndex + 文本。
    struct BlockEntry: Sendable {
        let pageIndex: Int
        let blockIndex: Int
        let text: String
    }

    /// 一次批量请求的去重/回填计划（纯数据，可独立测试）。
    struct BackfillPlan: Sendable {
        var items: [BatchTranslationItem] = []
        var cachedBackfills: [(pageIndex: Int, blockIndex: Int, translation: String)] = []
        var repIDToRefs: [String: [(pageIndex: Int, blockIndex: Int, text: String)]] = [:]
        var repIDToText: [String: String] = [:]
    }

    private func processImagesBatched(
        imageFiles: [String],
        extractDir: URL,
        outputDir: URL,
        ocrLangs: [String],
        settings: AppSettings,
        api: TranslationAPI,
        progressUpdate: @escaping @Sendable (TaskProgress) -> Void
    ) async throws -> ProcessingStats {
        let batchConcurrency = max(1, settings.batchConcurrency)
        let maxPagesPerBatch = max(1, settings.batchPagesLimit)
        let requestedImageConcurrency = max(1, settings.taskConcurrency)
        let imageConcurrency = min(requestedImageConcurrency, max(1, imageFiles.count))

        let config = BatchProcessingConfig(
            sourceLang: settings.sourceLang,
            targetLang: settings.targetLang,
            domainKey: settings.domain.rawValue,
            batchConcurrency: batchConcurrency,
            maxPagesPerBatch: maxPagesPerBatch
        )

        addLog(.info, "   🧠 跨页批量翻译：\(batchConcurrency) 路并发，每批最多 \(maxPagesPerBatch) 页")
        addLog(.info, "   ⚙️ OCR 处理并发: \(imageConcurrency) | 翻译并发: \(batchConcurrency)")

        let batchLog: BatchLogHandler = { [weak self] level, message in
            Task { @MainActor [weak self] in
                self?.addLog(level, message)
            }
        }

        let progressReporter = ImageProgressReporter(totalFiles: imageFiles.count, progressUpdate: progressUpdate)

        // 阶段 1：对每页做 OCR / 文本合并，得到 PreparedPage。
        let prepareStart = CFAbsoluteTimeGetCurrent()
        batchLog(.info, "   🔍 OCR 阶段开始：共 " + String(imageFiles.count) + " 张图片，页面处理并发 " + String(imageConcurrency))
        let prepared = try await Self.preparePagesForBatching(
            imageFiles: imageFiles,
            extractDir: extractDir,
            outputDir: outputDir,
            ocrLangs: ocrLangs,
            config: config,
            ocrEngine: ocrEngine,
            progressReporter: progressReporter,
            imageConcurrency: imageConcurrency
        )
        var stats = prepared.stats
        let prepareTime = CFAbsoluteTimeGetCurrent() - prepareStart
        let textBlockCount = prepared.pages.reduce(0) { $0 + $1.mergedBlocks.count }
        batchLog(.success, "   ✅ OCR 阶段结束：耗时 " + formatElapsed(prepareTime) + "，" + String(prepared.pages.count) + " 页含文本，" + String(textBlockCount) + " 个文本块")
        addLog(.info, "   🔍 预处理完成：\(prepared.pages.count) 页含文本，\(textBlockCount) 个文本块 | \(stats.skipped) 无文字, \(stats.failed) 失败 [\(formatElapsed(prepareTime))]")

        guard !prepared.pages.isEmpty else {
            try Task.checkCancellation()
            return stats
        }

        // 阶段 2：BatchPlanner 按 N/W/B 自适应分组（W=批量并发，B=每批页数上限）。
        let pageGroups = BatchPlanner.planPageIndices(
            pageCount: prepared.pages.count,
            concurrency: batchConcurrency,
            maxPagesPerBatch: maxPagesPerBatch
        )
        let batchSummary = pageGroups.enumerated().map { (idx, pages) -> String in
            let actualPages = pages.map { prepared.pages[$0].pageIndex }
            let range = actualPages.count == 1 ? "\(actualPages[0])" : "\(actualPages.first!)-\(actualPages.last!)"
            return "批\(idx + 1)[\(pages.count)]页\(range)"
        }.joined(separator: " ")
        addLog(.info, "   📦 \(pageGroups.count) 个批次：" + batchSummary)
        let theoreticalRounds = (pageGroups.count + batchConcurrency - 1) / batchConcurrency
        addLog(.info, "   🚦 批量请求并发上限：\(batchConcurrency) 路 | 每批最多 \(maxPagesPerBatch) 页 | 理论至少 \(theoreticalRounds) 轮")

        // 阶段 3：按 batch id 调用 api.translateBatch；用信号量限制并发 ≤ W。
        let semaphore = AsyncSemaphore(value: batchConcurrency)
        let executionTracker = BatchExecutionTracker()
        let translationTracker = BatchExecutionTracker()
        try await withThrowingTaskGroup(of: ProcessingStats.self) { group in
            for (batchIndex, pageIndices) in pageGroups.enumerated() {
                let batchID = String(batchIndex + 1)
                let groupPages = pageIndices.map { prepared.pages[$0] }
                group.addTask { [extractDir, outputDir, config, api, cache, semaphore, progressReporter, executionTracker, translationTracker, batchLog] in
                    await semaphore.wait()
                    if Task.isCancelled {
                        await semaphore.signal()
                        throw CancellationError()
                    }
                    let active = await executionTracker.begin()
                    let batchStart = CFAbsoluteTimeGetCurrent()
                    batchLog(.info, "   ▶️ [批次 " + batchID + "] 开始执行 | " + String(groupPages.count) + " 张图片 | 当前批次任务并发 " + String(active) + "/" + String(batchConcurrency))
                    do {
                        let batchStats = try await Self.processBatchGroup(
                            batchID: batchID,
                            pages: groupPages,
                            extractDir: extractDir,
                            outputDir: outputDir,
                            config: config,
                            api: api,
                            cache: cache,
                            progressReporter: progressReporter,
                            batchLog: batchLog,
                            translationTracker: translationTracker
                        )
                        let remaining = await executionTracker.end()
                        await semaphore.signal()
                        batchLog(.success, "   ✅ [批次 " + batchID + "] 执行结束 | 耗时 " + String(format: "%.1fs", CFAbsoluteTimeGetCurrent() - batchStart) + " | 当前批次任务并发 " + String(remaining) + "/" + String(batchConcurrency))
                        return batchStats
                    } catch {
                        let remaining = await executionTracker.end()
                        await semaphore.signal()
                        if Task.isCancelled || error is CancellationError {
                            throw CancellationError()
                        }
                        batchLog(.error, "   ❌ [批次 " + batchID + "] 执行失败 | 耗时 " + String(format: "%.1fs", CFAbsoluteTimeGetCurrent() - batchStart) + " | 当前批次任务并发 " + String(remaining) + "/" + String(batchConcurrency) + " | " + error.localizedDescription)
                        throw error
                    }
                }
            }
            for try await batchStats in group {
                stats.merge(batchStats)
            }
        }
        try Task.checkCancellation()

        addLog(.info, "   🔁 批次首请求: \(stats.batchRequestCount)（每批首选 1 次 translateBatch；重试/拆分会额外增加） | 回退: \(stats.fallbackCount) | 未翻译文本块: \(stats.untranslatedBlocks) | 翻译耗时: \(formatElapsed(stats.translateTime))")
        addLog(.info, "   📊 渲染完成：\(stats.translated) 页成功, \(stats.failed) 失败 | 渲染耗时: \(formatElapsed(stats.renderTime))")

        return stats
    }

    nonisolated private static func preparePagesForBatching(
        imageFiles: [String],
        extractDir: URL,
        outputDir: URL,
        ocrLangs: [String],
        config: BatchProcessingConfig,
        ocrEngine: OCREngine,
        progressReporter: ImageProgressReporter,
        imageConcurrency: Int
    ) async throws -> (pages: [PreparedPage], stats: ProcessingStats) {
        let imageSemaphore = AsyncSemaphore(value: imageConcurrency)
        var pageSlots: [PreparedPage?] = Array(repeating: nil, count: imageFiles.count)
        var stats = ProcessingStats()

        try await withThrowingTaskGroup(of: PrepareResult.self) { group in
            for (index, relativePath) in imageFiles.enumerated() {
                group.addTask { [extractDir, outputDir, ocrLangs, ocrEngine, progressReporter, imageSemaphore] in
                    await imageSemaphore.wait()
                    do {
                        let result = try await Self.preparePageForBatching(
                            index: index,
                            relativePath: relativePath,
                            extractDir: extractDir,
                            outputDir: outputDir,
                            ocrLangs: ocrLangs,
                            ocrEngine: ocrEngine,
                            progressReporter: progressReporter
                        )
                        await imageSemaphore.signal()
                        return result
                    } catch {
                        await imageSemaphore.signal()
                        throw error
                    }
                }
            }
            for try await result in group {
                stats.merge(result.stats)
                if let page = result.page {
                    pageSlots[page.pageIndex] = page
                }
            }
        }

        return (pageSlots.compactMap { $0 }, stats)
    }

    /// 对单页做 OCR + 文本合并；无文字/失败时原样复制并计入 skipped/failed。
    nonisolated private static func preparePageForBatching(
        index: Int,
        relativePath: String,
        extractDir: URL,
        outputDir: URL,
        ocrLangs: [String],
        ocrEngine: OCREngine,
        progressReporter: ImageProgressReporter
    ) async throws -> PrepareResult {
        try Task.checkCancellation()
        var stats = ProcessingStats()
        let inputURL = extractDir.appendingPathComponent(relativePath)
        let outputURL = outputDir.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        await progressReporter.report(stage: .ocr, index: index, fileName: relativePath, message: "OCR 识别")

        let cgImageOpt: CGImage? = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return img
        }.value

        guard let cgImage = cgImageOpt else {
            Self.safeCopy(from: inputURL, to: outputURL)
            stats.failed += 1
            return PrepareResult(page: nil, stats: stats)
        }

        let stepStart = CFAbsoluteTimeGetCurrent()
        let ocrResults: [OCRResult]
        do {
            ocrResults = try await ocrEngine.recognize(image: cgImage, languages: ocrLangs)
        } catch {
            Self.safeCopy(from: inputURL, to: outputURL)
            stats.failed += 1
            return PrepareResult(page: nil, stats: stats)
        }
        stats.ocrTime += CFAbsoluteTimeGetCurrent() - stepStart

        let validOCR = ocrResults.filter { $0.boundingBox.width > 0.001 && $0.boundingBox.height > 0.001 }
        if validOCR.isEmpty {
            Self.safeCopy(from: inputURL, to: outputURL)
            stats.skipped += 1
            return PrepareResult(page: nil, stats: stats)
        }

        let textBlocks = validOCR.map { TextBlock(from: $0) }
        let regions = RegionSegmenter().segment(blocks: textBlocks)
        let textMerger = TextMerger()
        let mergedBlocks = regions.flatMap { textMerger.merge(blocks: $0.blocks) }

        if mergedBlocks.isEmpty {
            Self.safeCopy(from: inputURL, to: outputURL)
            stats.skipped += 1
            return PrepareResult(page: nil, stats: stats)
        }

        return PrepareResult(
            page: PreparedPage(
                pageIndex: index,
                relativePath: relativePath,
                image: SendableImage(image: cgImage),
                mergedBlocks: mergedBlocks
            ),
            stats: stats
        )
    }

    nonisolated private static func processBatchGroup(
        batchID: String,
        pages: [PreparedPage],
        extractDir: URL,
        outputDir: URL,
        config: BatchProcessingConfig,
        api: TranslationAPI,
        cache: TranslationCache,
        progressReporter: ImageProgressReporter,
        batchLog: @escaping BatchLogHandler,
        translationTracker: BatchExecutionTracker
    ) async throws -> ProcessingStats {
        try await translateAndRenderGroup(
            batchID: batchID,
            pages: pages,
            extractDir: extractDir,
            outputDir: outputDir,
            config: config,
            api: api,
            cache: cache,
            progressReporter: progressReporter,
            batchLog: batchLog,
            translationTracker: translationTracker
        )
    }

    /// 对一个批次做：去重+缓存 → api.translateBatch（失败重试一次）→ 仍失败拆半 → 单页回退 translateTextsBatch。
    nonisolated private static func translateAndRenderGroup(
        batchID: String,
        pages: [PreparedPage],
        extractDir: URL,
        outputDir: URL,
        config: BatchProcessingConfig,
        api: TranslationAPI,
        cache: TranslationCache,
        progressReporter: ImageProgressReporter,
        batchLog: @escaping BatchLogHandler,
        translationTracker: BatchExecutionTracker
    ) async throws -> ProcessingStats {
        try Task.checkCancellation()

        let plan = await Self.buildBackfillPlan(pages: pages, config: config, cache: cache)
        let rawTexts = pages.flatMap { $0.mergedBlocks.map(\.text) }
        let rawCharacterCount = rawTexts.reduce(0) { $0 + $1.count }
        let rawByteCount = rawTexts.reduce(0) { $0 + $1.utf8.count }
        let requestCharacterCount = plan.items.reduce(0) { $0 + $1.text.count }
        let requestByteCount = plan.items.reduce(0) { $0 + $1.text.utf8.count }
        batchLog(.info, "   🧾 [批次 " + batchID + "] 数据统计 | 图片 " + String(pages.count) + " 张 | 原始文本块 " + String(rawTexts.count) + " | 原始字符 " + String(rawCharacterCount) + " | 原始 UTF-8 字节 " + String(rawByteCount) + " | 实际发送文本块 " + String(plan.items.count) + " | 实际发送字符 " + String(requestCharacterCount) + " | 实际发送 UTF-8 字节 " + String(requestByteCount) + " | 缓存命中 " + String(plan.cachedBackfills.count))

        // 全部命中缓存：无需请求，直接渲染。
        if plan.items.isEmpty {
            batchLog(.info, "   ⏭️ [批次 " + batchID + "] 翻译阶段跳过：全部文本命中缓存")
            let renderStart = CFAbsoluteTimeGetCurrent()
            batchLog(.info, "   🎨 [批次 " + batchID + "] 渲染开始 | " + String(pages.count) + " 张图片")
            let map = Self.buildTranslations(pages: pages, plan: plan, resolved: [:])
            let renderStats = try await Self.renderPages(
                pages: pages,
                translationsByPage: map,
                extractDir: extractDir,
                outputDir: outputDir,
                progressReporter: progressReporter
            )
            batchLog(.success, "   ✅ [批次 " + batchID + "] 渲染结束 | 耗时 " + String(format: "%.1fs", CFAbsoluteTimeGetCurrent() - renderStart))
            return renderStats
        }

        for page in pages {
            await progressReporter.report(
                stage: .translating,
                index: page.pageIndex,
                fileName: page.relativePath,
                message: "翻译 \(page.mergedBlocks.count) 段"
            )
        }

        var stats = ProcessingStats()
        stats.batchRequestCount += 1
        var resolved: [String: String] = [:]
        let requestStart = CFAbsoluteTimeGetCurrent()
        var succeeded = false
        let apiActive = await translationTracker.begin()
        batchLog(.info, "   🌐 [批次 " + batchID + "] 翻译 API 开始 | 当前 API 并发 " + String(apiActive) + "/" + String(config.batchConcurrency) + " | 首请求 1 次 | 文本块 " + String(plan.items.count) + " | 字符 " + String(requestCharacterCount))

        do {
            try Task.checkCancellation()
            let results = try await Self.requestBatchWithRetry(
                api: api,
                items: plan.items,
                source: config.sourceLang,
                target: config.targetLang,
                batchID: batchID,
                batchLog: batchLog
            )
            stats.translateTime += CFAbsoluteTimeGetCurrent() - requestStart
            for r in results { resolved[r.id] = r.text }
            succeeded = true
            let apiRemaining = await translationTracker.end()
            batchLog(.success, "   ✅ [批次 " + batchID + "] 翻译 API 结束 | 耗时 " + String(format: "%.1fs", CFAbsoluteTimeGetCurrent() - requestStart) + " | 返回 " + String(results.count) + " 项 | 当前 API 并发 " + String(apiRemaining) + "/" + String(config.batchConcurrency))
        } catch {
            stats.translateTime += CFAbsoluteTimeGetCurrent() - requestStart
            let apiRemaining = await translationTracker.end()
            if Task.isCancelled { throw CancellationError() }
            batchLog(.error, "   ❌ [批次 " + batchID + "] 翻译 API 结束但未通过校验 | 耗时 " + String(format: "%.1fs", CFAbsoluteTimeGetCurrent() - requestStart) + " | 当前 API 并发 " + String(apiRemaining) + "/" + String(config.batchConcurrency) + " | " + error.localizedDescription + " | 将拆分或回退")
        }

        if succeeded {
            // 成功后逐条写入现有 TranslationCache。
            for item in plan.items {
                if let t = resolved[item.id], !t.isEmpty {
                    await cache.set(item.text, config.sourceLang, config.targetLang, t, config.domainKey)
                }
            }
            let map = Self.buildTranslations(pages: pages, plan: plan, resolved: resolved)
            try Task.checkCancellation()
            let renderStart = CFAbsoluteTimeGetCurrent()
            batchLog(.info, "   🎨 [批次 " + batchID + "] 渲染开始 | " + String(pages.count) + " 张图片")
            let renderStats = try await Self.renderPages(
                pages: pages,
                translationsByPage: map,
                extractDir: extractDir,
                outputDir: outputDir,
                progressReporter: progressReporter
            )
            batchLog(.success, "   ✅ [批次 " + batchID + "] 渲染结束 | 耗时 " + String(format: "%.1fs", CFAbsoluteTimeGetCurrent() - renderStart) + " | 成功 " + String(renderStats.translated) + " 张 | 失败 " + String(renderStats.failed) + " 张 | 未翻译文本块 " + String(renderStats.untranslatedBlocks))
            stats.merge(renderStats)
            return stats
        } else {
            // 仍失败：拆半递归；单页则回退到单文本 translateTextsBatch。
            if pages.count > 1 {
                batchLog(.warning, "   ✂️ [批次 " + batchID + "] 开始拆分 | 原批次 " + String(pages.count) + " 张图片 | 原因：批量响应不完整或请求失败")
                let mid = pages.count / 2
                let left = try await translateAndRenderGroup(
                    batchID: batchID + ".1",
                    pages: Array(pages[..<mid]),
                    extractDir: extractDir,
                    outputDir: outputDir,
                    config: config,
                    api: api,
                    cache: cache,
                    progressReporter: progressReporter,
                    batchLog: batchLog,
                    translationTracker: translationTracker
                )
                let right = try await translateAndRenderGroup(
                    batchID: batchID + ".2",
                    pages: Array(pages[mid...]),
                    extractDir: extractDir,
                    outputDir: outputDir,
                    config: config,
                    api: api,
                    cache: cache,
                    progressReporter: progressReporter,
                    batchLog: batchLog,
                    translationTracker: translationTracker
                )
                var merged = ProcessingStats()
                merged.merge(left)
                merged.merge(right)
                merged.batchRequestCount += stats.batchRequestCount
                merged.translateTime += stats.translateTime
                merged.fallbackCount += 1
                batchLog(.info, "   🔁 [批次 " + batchID + "] 拆分完成 | 子批次已分别处理")
                return merged
            } else {
                stats.fallbackCount += 1
                batchLog(.warning, "   ↩️ [批次 " + batchID + "] 进入单页回退 | 图片 1 张")
                let fb = try await Self.fallbackSinglePage(
                    batchID: batchID,
                    pages: pages,
                    extractDir: extractDir,
                    outputDir: outputDir,
                    config: config,
                    api: api,
                    cache: cache,
                    progressReporter: progressReporter,
                    batchLog: batchLog
                )
                stats.merge(fb)
                return stats
            }
        }
    }

    /// 批量请求失败（含 JSON 校验失败）时重试一次。
    nonisolated static func requestBatchWithRetry(
        api: TranslationAPI,
        items: [BatchTranslationItem],
        source: String,
        target: String,
        batchID: String = "",
        batchLog: BatchLogHandler? = nil
    ) async throws -> [BatchTranslationResult] {
        for attempt in 1...2 {
            let attemptStart = CFAbsoluteTimeGetCurrent()
            if !batchID.isEmpty {
                batchLog?(.info, "   ↻ [批次 " + batchID + "] API 第 " + String(attempt) + " 次请求开始")
            }
            do {
                let results = try await api.translateBatch(items, from: source, to: target)
                if !batchID.isEmpty {
                    batchLog?(.success, "   ✓ [批次 " + batchID + "] API 第 " + String(attempt) + " 次请求结束 | 耗时 " + String(format: "%.1fs", CFAbsoluteTimeGetCurrent() - attemptStart))
                }
                return results
            } catch {
                if Task.isCancelled || error is CancellationError {
                    if !batchID.isEmpty {
                        batchLog?(.warning, "   ⏹️ [批次 " + batchID + "] API 请求已取消")
                    }
                    throw CancellationError()
                }
                if !batchID.isEmpty {
                    batchLog?(.error, "   ⚠️ [批次 " + batchID + "] API 第 " + String(attempt) + " 次请求失败 | 耗时 " + String(format: "%.1fs", CFAbsoluteTimeGetCurrent() - attemptStart) + " | " + error.localizedDescription)
                }
                if attempt == 2 { throw error }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        throw CancellationError()
    }

    /// 纯函数：由块列表 + 缓存命中表构建去重/回填计划。可独立测试。
    nonisolated static func buildBlockPlan(
        blocks: [BlockEntry],
        cached: [String: String]
    ) -> BackfillPlan {
        var plan = BackfillPlan()
        var textToRepID: [String: String] = [:]
        for entry in blocks {
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let cachedTranslation = cached[trimmed] {
                plan.cachedBackfills.append((entry.pageIndex, entry.blockIndex, cachedTranslation))
            } else if let repID = textToRepID[trimmed] {
                plan.repIDToRefs[repID]!.append((entry.pageIndex, entry.blockIndex, trimmed))
            } else {
                let repID = "p\(entry.pageIndex)_b\(entry.blockIndex)"
                textToRepID[trimmed] = repID
                plan.repIDToRefs[repID] = [(entry.pageIndex, entry.blockIndex, trimmed)]
                plan.repIDToText[repID] = trimmed
                plan.items.append(BatchTranslationItem(id: repID, text: trimmed))
            }
        }
        return plan
    }

    nonisolated private static func buildBackfillPlan(
        pages: [PreparedPage],
        config: BatchProcessingConfig,
        cache: TranslationCache
    ) async -> BackfillPlan {
        var entries: [BlockEntry] = []
        var uniqueTexts: [String] = []
        var seen = Set<String>()
        for page in pages {
            for (blockIndex, block) in page.mergedBlocks.enumerated() {
                let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                entries.append(BlockEntry(pageIndex: page.pageIndex, blockIndex: blockIndex, text: block.text))
                if !seen.contains(trimmed) {
                    seen.insert(trimmed)
                    uniqueTexts.append(trimmed)
                }
            }
        }
        var cached: [String: String] = [:]
        for text in uniqueTexts {
            if let c = await cache.get(text, config.sourceLang, config.targetLang, config.domainKey) {
                cached[text] = c
            }
        }
        return Self.buildBlockPlan(blocks: entries, cached: cached)
    }

    nonisolated private static func buildTranslations(
        pages: [PreparedPage],
        plan: BackfillPlan,
        resolved: [String: String]
    ) -> [Int: [String]] {
        var map: [Int: [String]] = [:]
        for page in pages {
            map[page.pageIndex] = Array(repeating: "", count: page.mergedBlocks.count)
        }
        for (pageIndex, blockIndex, translation) in plan.cachedBackfills {
            map[pageIndex]?[blockIndex] = translation
        }
        for (repID, refs) in plan.repIDToRefs {
            let translation = resolved[repID] ?? ""
            for (pageIndex, blockIndex, _) in refs {
                map[pageIndex]?[blockIndex] = translation
            }
        }
        return map
    }

    nonisolated private static func renderPages(
        pages: [PreparedPage],
        translationsByPage: [Int: [String]],
        extractDir: URL,
        outputDir: URL,
        progressReporter: ImageProgressReporter
    ) async throws -> ProcessingStats {
        var stats = ProcessingStats()
        for page in pages {
            try Task.checkCancellation()
            let translations = translationsByPage[page.pageIndex] ?? []
            let missingCount = page.mergedBlocks.indices.reduce(0) { count, index in
                count + (index >= translations.count || translations[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0)
            }
            stats.untranslatedBlocks += missingCount
            await progressReporter.report(stage: .rendering, index: page.pageIndex, fileName: page.relativePath, message: "渲染")
            let renderStart = CFAbsoluteTimeGetCurrent()
            let ok = await Self.renderPage(
                page: page,
                outputDir: outputDir,
                translations: translations
            )
            stats.renderTime += CFAbsoluteTimeGetCurrent() - renderStart
            if ok {
                stats.translated += 1
            } else {
                Self.safeCopy(
                    from: extractDir.appendingPathComponent(page.relativePath),
                    to: outputDir.appendingPathComponent(page.relativePath)
                )
                stats.failed += 1
            }
        }
        return stats
    }

    nonisolated private static func renderPage(
        page: PreparedPage,
        outputDir: URL,
        translations: [String]
    ) async -> Bool {
        let outputURL = outputDir.appendingPathComponent(page.relativePath)
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return await Task.detached(priority: .userInitiated) {
            guard let rendered = ImageRenderer.renderTranslated(
                original: page.image.image,
                textBlocks: page.mergedBlocks,
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
    }

    /// 单页批量彻底失败后的回退：退化为现有单文本 translateTextsBatch。
    nonisolated private static func fallbackSinglePage(
        batchID: String,
        pages: [PreparedPage],
        extractDir: URL,
        outputDir: URL,
        config: BatchProcessingConfig,
        api: TranslationAPI,
        cache: TranslationCache,
        progressReporter: ImageProgressReporter,
        batchLog: @escaping BatchLogHandler
    ) async throws -> ProcessingStats {
        var stats = ProcessingStats()
        for page in pages {
            try Task.checkCancellation()
            let texts = page.mergedBlocks.map(\.text)
            let concurrency = max(1, min(config.batchConcurrency, texts.count))
            let translateStart = CFAbsoluteTimeGetCurrent()
            var translations = await translateTextsBatch(
                texts: texts,
                from: config.sourceLang,
                to: config.targetLang,
                api: api,
                cache: cache,
                concurrency: concurrency,
                domainKey: config.domainKey
            )
            stats.translateTime += CFAbsoluteTimeGetCurrent() - translateStart

            // 单页回退后仍为空的文本块，再用单项结构化批量请求补偿一次，避免静默漏翻译。
            let unresolved = texts.indices.filter { translations[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !unresolved.isEmpty {
                batchLog(.warning, "   🔧 [批次 " + batchID + "] 单页回退后仍有 " + String(unresolved.count) + " 个未翻译文本块，开始逐块补偿")
            }
            for index in texts.indices where translations[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try Task.checkCancellation()
                let item = BatchTranslationItem(id: "p\(page.pageIndex)_b\(index)", text: texts[index].trimmingCharacters(in: .whitespacesAndNewlines))
                guard !item.text.isEmpty else { continue }
                let retryStart = CFAbsoluteTimeGetCurrent()
                if let result = try? await Self.requestBatchWithRetry(
                    api: api,
                    items: [item],
                    source: config.sourceLang,
                    target: config.targetLang,
                    batchID: batchID + ".b" + String(index),
                    batchLog: batchLog
                ), let recovered = result.first?.text {
                    let cleanedRecovered = recovered.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if !cleanedRecovered.isEmpty {
                        translations[index] = recovered
                        await cache.set(item.text, config.sourceLang, config.targetLang, recovered, config.domainKey)
                        batchLog(.success, "   ✅ [批次 " + batchID + "] 文本块 b" + String(index) + " 补偿成功")
                    } else {
                        batchLog(.error, "   ❌ [批次 " + batchID + "] 文本块 b" + String(index) + " 补偿失败，将保留原文")
                    }
                } else {
                    batchLog(.error, "   ❌ [批次 " + batchID + "] 文本块 b" + String(index) + " 补偿失败，将保留原文")
                }
                stats.batchRequestCount += 1
                stats.translateTime += CFAbsoluteTimeGetCurrent() - retryStart
            }
            try Task.checkCancellation()
            let renderStats = try await Self.renderPages(
                pages: [page],
                translationsByPage: [page.pageIndex: translations],
                extractDir: extractDir,
                outputDir: outputDir,
                progressReporter: progressReporter
            )
            stats.merge(renderStats)
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
