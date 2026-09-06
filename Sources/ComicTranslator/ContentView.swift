import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var settings = AppSettings()
    @StateObject private var translator = ComicTranslator()

    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var apiStatus: APIStatus = .unknown
    @State private var isDropTargeted: Bool = false

    enum APIStatus {
        case unknown, connected, failed
    }

    var body: some View {
        HSplitView {
            // 左侧：设置面板
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerBanner
                    apiSection
                    languageSection
                    domainSection
                    advancedSection
                }
                .padding()
            }
            .frame(minWidth: 380)
            .background(Color(nsColor: .controlBackgroundColor))

            // 右侧：文件列表和日志
            VSplitView {
                fileListSection
                    .frame(minHeight: 240)

                logsView
                    .frame(minHeight: 180)
            }
            .frame(minWidth: 460)
        }
        .frame(minWidth: 860, minHeight: 640)
    }

    // MARK: - 顶部标题

    private var headerBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.book.closed.fill")
                .font(.title2)
                .foregroundStyle(.linearGradient(
                    colors: [.blue, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            VStack(alignment: .leading, spacing: 2) {
                Text("漫画翻译器")
                    .font(.headline)
                Text("v1.2.0")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: - 文件列表区

    private var fileListSection: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("待翻译文件", systemImage: "doc.on.doc.fill")
                    .font(.callout.bold())
                    .foregroundStyle(.primary)

                if !translator.fileTasks.isEmpty {
                    Text("(\(translator.overallProgress.current)/\(translator.overallProgress.total))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.1)))
                }

                Spacer()

                HStack(spacing: 6) {
                    Button {
                        selectFiles()
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(translator.isProcessing)

                    if !translator.fileTasks.isEmpty {
                        Button {
                            translator.clearFiles()
                        } label: {
                            Label("清空", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                        .disabled(translator.isProcessing)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            // 文件列表
            if translator.fileTasks.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(translator.fileTasks) { task in
                            fileTaskRow(task)
                        }
                    }
                    .padding(10)
                }
            }

            Divider()

            // 底部操作栏
            actionBar
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTargeted
                        ? Color.accentColor.opacity(0.8)
                        : Color.clear,
                    lineWidth: 2.5
                )
                .padding(3)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(width: 80, height: 80)
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.linearGradient(
                        colors: [.blue.opacity(0.6), .purple.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
            }
            Text("拖拽文件到这里")
                .font(.callout.bold())
                .foregroundStyle(.secondary)
            Text("支持 PDF、压缩包 (ZIP/CBZ/RAR/7z) 和音视频 (MP4/MP3/M4A 等)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func fileTaskRow(_ task: FileTask) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                statusIcon(for: task.status)

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.inputURL.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let output = task.outputURL {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                            Text(output.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption)
                        .foregroundStyle(.green)
                    } else if let err = task.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    } else if case .processing = task.status, let p = task.progress {
                        HStack(spacing: 4) {
                            Text(p.stage.rawValue)
                                .fontWeight(.medium)
                            Text("·")
                            Text(p.message)
                        }
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                    } else {
                        Text(statusText(for: task.status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // 单个文件操作
                if case .completed(let url) = task.status {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "folder")
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.borderless)
                    .help("在 Finder 中显示")
                }

                Button {
                    translator.removeFile(id: task.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .disabled(translator.isProcessing)
                .help("移除")
            }

            // 处理中的进度条
            if case .processing = task.status, let p = task.progress, p.totalFiles > 0 {
                ProgressView(value: Double(p.currentFile), total: Double(p.totalFiles))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(.blue)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor(for: task.status))
        )
    }

    @ViewBuilder
    private func statusIcon(for status: FileTaskStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.tertiary)
                .font(.body)
        case .processing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.body)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.body)
        }
    }

    private func statusText(for status: FileTaskStatus) -> String {
        status.label
    }

    private func backgroundColor(for status: FileTaskStatus) -> Color {
        switch status {
        case .pending: return Color.secondary.opacity(0.04)
        case .processing: return Color.blue.opacity(0.06)
        case .completed: return Color.green.opacity(0.06)
        case .failed: return Color.red.opacity(0.06)
        }
    }

    // MARK: - 操作栏

    private var actionBar: some View {
        HStack(spacing: 10) {
            if translator.batchCompleted, let last = translator.lastCompletedOutput {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([last])
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if translator.isProcessing {
                let prog = translator.overallProgress
                if prog.total > 0 {
                    ProgressView(value: Double(prog.current), total: Double(prog.total))
                        .frame(width: 100)
                        .tint(.blue)
                }
                Text("\(prog.current)/\(prog.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if translator.isProcessing {
                Button("取消", role: .cancel) {
                    translator.cancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(".", modifiers: .command)
            }

            Button {
                translator.translateBatch(settings: settings)
            } label: {
                if translator.isProcessing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("处理中...")
                    }
                } else {
                    Label("开始翻译 (\(translator.fileTasks.count))", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(translator.fileTasks.isEmpty || translator.isProcessing)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - API 配置

    private var apiSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("API 类型")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $settings.apiFormat) {
                        ForEach(APIFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: settings.apiFormat) { _, newValue in
                        if settings.apiEndpoint.isEmpty {
                            settings.apiEndpoint = newValue.defaultEndpoint
                        }
                    }
                }

                HStack {
                    Text("Endpoint")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    TextField("API URL", text: $settings.apiEndpoint)
                        .textFieldStyle(.roundedBorder)
                    apiStatusIcon
                }

                if settings.apiFormat == .openaiCompatible {
                    HStack {
                        Text("API Key")
                            .frame(width: 80, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        SecureField("Bearer token", text: $settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack {
                    Text("模型")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    if availableModels.isEmpty {
                        TextField("模型名称", text: $settings.modelID)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("", selection: $settings.modelID) {
                            ForEach(availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                            if !availableModels.contains(settings.modelID) {
                                Text(settings.modelID).tag(settings.modelID)
                            }
                        }
                        .labelsHidden()
                    }

                    Button {
                        refreshModels()
                    } label: {
                        if isLoadingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("获取可用模型列表")
                }

                HStack {
                    Text("")
                        .frame(width: 80)
                    Button("测试连接") {
                        testAPIConnection()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("翻译 API", systemImage: "network")
                .font(.callout.bold())
        }
    }

    @ViewBuilder
    private var apiStatusIcon: some View {
        switch apiStatus {
        case .unknown:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
                .help("未测试")
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("已连接")
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help("连接失败")
        }
    }

    // MARK: - 语言设置

    private var languageSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("源语言")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $settings.sourceLang) {
                        ForEach(LanguageOption.sourceLanguages) { lang in
                            Text(lang.name).tag(lang.id)
                        }
                    }
                    .labelsHidden()
                }

                HStack {
                    Text("目标语言")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $settings.targetLang) {
                        ForEach(LanguageOption.allLanguages) { lang in
                            Text(lang.name).tag(lang.id)
                        }
                    }
                    .labelsHidden()
                }

                HStack {
                    Text("输出格式")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $settings.outputFormat) {
                        ForEach(OutputFormat.allCases) { fmt in
                            Text(fmt.displayName).tag(fmt)
                        }
                    }
                    .labelsHidden()
                }

                Divider()

                HStack {
                    Text("字幕格式")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $settings.subtitleFormat) {
                        ForEach(SubtitleFormat.allCases) { fmt in
                            Text(fmt.displayName).tag(fmt)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 140)

                    Toggle("双语", isOn: $settings.subtitleBilingual)
                        .toggleStyle(.checkbox)
                        .help("输出原文+译文双语字幕")
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                        .font(.caption2)
                    Text("音频/视频文件将使用 macOS 语音识别转写后翻译，输出字幕文件")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("语言设置", systemImage: "globe")
                .font(.callout.bold())
        }
    }

    // MARK: - 领域优化

    private var domainSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    Picker("", selection: $settings.domain) {
                        ForEach(TranslationDomain.allCases) { domain in
                            Label(domain.displayName, systemImage: domain.icon).tag(domain)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }

                if settings.domain != .general {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.caption)
                        Text(settings.domain.shortDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.blue.opacity(0.05))
                    )
                }

                if settings.domain == .custom {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自定义领域提示词")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $settings.customDomainPrompt)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 80)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                        Text("描述该领域的翻译要求，如术语表、风格偏好等")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("领域优化", systemImage: "target")
                .font(.callout.bold())
        }
    }

    // MARK: - 高级设置

    private var advancedSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("OCR 处理并发")
                        .frame(width: 112, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Stepper(value: $settings.taskConcurrency, in: 1...16) {
                        Text("\(settings.taskConcurrency) 路并行")
                            .font(.callout.monospacedDigit())
                    }
                    .disabled(translator.isProcessing)
                }
                Text("控制 PDF 拆页、OCR 等页面级处理的同时任务数。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 116)

                HStack {
                    Text("翻译并发")
                        .frame(width: 112, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Stepper(value: $settings.batchConcurrency, in: 1...16) {
                        Text("\(settings.batchConcurrency) 路并行")
                            .font(.callout.monospacedDigit())
                    }
                    .disabled(translator.isProcessing)
                }
                Text("图片批量模式下控制同时发送的批次数；音视频字幕等兼容流程下控制并行 API 请求数。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 116)

                HStack {
                    Text("单批次最大页数")
                        .frame(width: 112, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Stepper(value: $settings.batchPagesLimit, in: 1...8) {
                        Text("\(settings.batchPagesLimit) 页/批")
                            .font(.callout.monospacedDigit())
                    }
                    .disabled(translator.isProcessing)
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                        .font(.caption2)
                    Text(batchRuleDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("温度")
                        .frame(width: 112, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Slider(value: $settings.temperature, in: 0...1, step: 0.1)
                    Text(String(format: "%.1f", settings.temperature))
                        .font(.callout.monospacedDigit())
                        .frame(width: 30)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("自定义 Prompt 模板（可选）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $settings.customPromptTemplate)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    Text("变量: {text} {items} {batch} {source} {target} {domain}")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
        } label: {
            Label("高级设置", systemImage: "gearshape.2")
                .font(.callout.bold())
        }
        .padding(.horizontal, 4)
    }

    /// 跨页分批说明：表达 N 页、W 路时的自适应均匀分批规则。
    private var batchRuleDescription: String {
        let pages = settings.batchPagesLimit
        let ways = settings.batchConcurrency
        return "按页数均匀分批，每批最多 \(pages) 页，同时最多发送 \(ways) 个批次；页数不足时也会拆成更小的批次。"
    }

    // MARK: - 日志

    private var logsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("日志", systemImage: "terminal")
                    .font(.callout.bold())

                if translator.isProcessing {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.leading, 4)
                }

                Spacer()

                if !translator.logs.isEmpty {
                    Text("\(translator.logs.count) 条")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 4)

                    Button {
                        translator.logs.removeAll()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("清空日志")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if translator.logs.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "text.alignleft")
                                    .font(.title3)
                                    .foregroundStyle(.tertiary)
                                Text("暂无日志")
                                    .foregroundStyle(.tertiary)
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        } else {
                            ForEach(translator.logs) { log in
                                logRow(log)
                                    .id(log.id)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: translator.logs.count) { _, _ in
                    if let last = translator.logs.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func logRow(_ log: LogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(logTimestamp(log.timestamp))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 55, alignment: .leading)

            Circle()
                .fill(colorForLevel(log.level))
                .frame(width: 5, height: 5)

            Text(log.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(textColorForLevel(log.level))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func logTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func colorForLevel(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func textColorForLevel(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .primary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    // MARK: - 动作

    // MARK: - 支持的文件类型

    private static let archiveExts = ["zip", "cbz", "rar", "cbr", "7z", "gz", "bz2", "xz", "tar", "tgz"]
    private static let documentExts = ["pdf"]
    private static let audioExts = ["m4a", "mp3", "wav", "aac", "flac", "aiff", "aif", "caf"]
    private static let videoExts = ["mp4", "m4v", "mov", "avi", "mkv", "webm", "flv", "wmv", "mpg", "mpeg"]

    private static var allSupportedExts: [String] {
        documentExts + archiveExts + audioExts + videoExts
    }

    private static func isSupportedFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return allSupportedExts.contains(ext)
            || ArchiveFormat.from(fileName: url.lastPathComponent) != nil
    }

    private func selectFiles() {
        let panel = NSOpenPanel()
        var types: [UTType] = []
        for ext in Self.allSupportedExts {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        if types.isEmpty { types = [.data] }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "选择 PDF、压缩包、音频或视频（可多选）"

        if panel.runModal() == .OK {
            translator.addFiles(panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        let lock = NSLock()
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let filtered = urls.filter { Self.isSupportedFile($0) }
            if !filtered.isEmpty {
                self.translator.addFiles(filtered)
            }
        }
    }

    private func refreshModels() {
        isLoadingModels = true
        let config = TranslationConfig(
            endpoint: settings.apiEndpoint,
            apiKey: settings.apiKey,
            modelID: settings.modelID,
            temperature: settings.temperature,
            customPromptTemplate: settings.customPromptTemplate,
            domainInstruction: settings.domain.systemInstruction(customPrompt: settings.customDomainPrompt)
        )
        let api = makeTranslationAPI(format: settings.apiFormat, config: config)
        Task { @MainActor in
            let models = await api.listModels()
            self.availableModels = models
            self.isLoadingModels = false
        }
    }

    private func testAPIConnection() {
        apiStatus = .unknown
        let config = TranslationConfig(
            endpoint: settings.apiEndpoint,
            apiKey: settings.apiKey,
            modelID: settings.modelID,
            temperature: settings.temperature,
            customPromptTemplate: settings.customPromptTemplate,
            domainInstruction: settings.domain.systemInstruction(customPrompt: settings.customDomainPrompt)
        )
        let api = makeTranslationAPI(format: settings.apiFormat, config: config)
        Task { @MainActor in
            let ok = await api.testConnection()
            self.apiStatus = ok ? .connected : .failed
        }
    }
}
