import Foundation

// MARK: - 翻译协议

protocol TranslationAPI: Sendable {
    func translate(text: String, from source: String, to target: String) async throws -> String
    func translateBatch(_ items: [BatchTranslationItem], from source: String, to target: String) async throws -> [BatchTranslationResult]
    func testConnection() async -> Bool
    func listModels() async -> [String]
}

// 默认实现：后端若未提供批量接口，则退化为逐个调用单文本 translate，保持旧接口兼容。
extension TranslationAPI {
    func translateBatch(_ items: [BatchTranslationItem], from source: String, to target: String) async throws -> [BatchTranslationResult] {
        guard !items.isEmpty else { return [] }
        var results: [BatchTranslationResult] = []
        results.reserveCapacity(items.count)
        for item in items {
            let text = try await translate(text: item.text, from: source, to: target)
            results.append(BatchTranslationResult(id: item.id, text: text))
        }
        return results
    }
}

// MARK: - 批量翻译数据

struct BatchTranslationItem: Sendable, Hashable {
    let id: String
    let text: String

    init(id: String, text: String) {
        self.id = id
        self.text = text
    }

    /// 基于文本生成稳定的 id，便于同一文本在多次请求间复用。
    init(text: String) {
        self.init(id: Self.stableID(for: text), text: text)
    }

    /// 确定性哈希（FNV-1a 64bit），输出 JSON 安全且跨进程稳定。
    static func stableID(for text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "txt_%016llx", hash)
    }
}

struct BatchTranslationResult: Sendable, Hashable {
    let id: String
    let text: String

    init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

// MARK: - 翻译配置

struct TranslationConfig: Sendable {
    let endpoint: String
    let apiKey: String
    let modelID: String
    let temperature: Double
    let customPromptTemplate: String
    let domainInstruction: String  // 领域指令（来自 TranslationDomain.systemInstruction）
}

enum TranslationAPIError: Error, LocalizedError {
    case invalidEndpoint
    case httpError(Int, String)
    case parseError(String)
    case emptyContent(String)
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "无效的 API endpoint"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .parseError(let msg): return "响应解析失败: \(msg)"
        case .emptyContent(let detail): return "API 返回空 content: \(detail)"
        case .connectionFailed: return "连接失败"
        }
    }
}

// MARK: - 工厂方法

func makeTranslationAPI(format: APIFormat, config: TranslationConfig) -> TranslationAPI {
    switch format {
    case .ollama:
        return OllamaAPI(config: config)
    case .hyMT:
        return HYMTAPI(config: config)
    case .openaiCompatible:
        return OpenAICompatibleAPI(config: config)
    }
}

// MARK: - Ollama（通用本地模型）

struct OllamaAPI: TranslationAPI {
    let config: TranslationConfig

    func translate(text: String, from source: String, to target: String) async throws -> String {
        let prompt = buildPrompt(text: text, source: source, target: target)

        let body: [String: Any] = [
            "model": config.modelID,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "stream": false,
            "options": [
                "temperature": config.temperature,
                "top_p": 0.6,
                "top_k": 20,
                "repeat_penalty": 1.05
            ]
        ]

        let data = try await postJSON(to: "\(config.endpoint)/api/chat", body: body)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationAPIError.parseError("Ollama 响应格式错误")
        }

        return cleanResponse(content)
    }

    func translateBatch(_ items: [BatchTranslationItem], from source: String, to target: String) async throws -> [BatchTranslationResult] {
        try await performOllamaStyleBatch(config: config, items: items, source: source, target: target)
    }

    func testConnection() async -> Bool {
        guard let url = URL(string: "\(config.endpoint)/api/tags") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func listModels() async -> [String] {
        guard let url = URL(string: "\(config.endpoint)/api/tags") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["name"] as? String }
        } catch {
            return []
        }
    }

    private func buildPrompt(text: String, source: String, target: String) -> String {
        let customPromptTemplate = config.customPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customPromptTemplate.isEmpty {
            return applyTemplate(customPromptTemplate, text: text, source: source, target: target, domain: config.domainInstruction)
        }
        let targetName = LanguageOption.named(target)?.name ?? target
        var parts: [String] = []
        if !config.domainInstruction.isEmpty {
            parts.append(config.domainInstruction)
        }
        parts.append("将以下文本翻译为\(targetName)，不要添加任何解释，只输出译文：")
        parts.append(text)
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - HY-MT（腾讯混元翻译，使用 Ollama 后端）

struct HYMTAPI: TranslationAPI {
    let config: TranslationConfig

    func translate(text: String, from source: String, to target: String) async throws -> String {
        let prompt = buildPrompt(text: text, source: source, target: target)

        let body: [String: Any] = [
            "model": config.modelID,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "stream": false,
            "options": [
                "temperature": config.temperature,
                "top_p": 0.6,
                "top_k": 20,
                "repeat_penalty": 1.05
            ]
        ]

        let data = try await postJSON(to: "\(config.endpoint)/api/chat", body: body)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationAPIError.parseError("HY-MT 响应格式错误")
        }

        return cleanResponse(content)
    }

    func translateBatch(_ items: [BatchTranslationItem], from source: String, to target: String) async throws -> [BatchTranslationResult] {
        try await performOllamaStyleBatch(config: config, items: items, source: source, target: target)
    }

    func testConnection() async -> Bool {
        guard let url = URL(string: "\(config.endpoint)/api/tags") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func listModels() async -> [String] {
        guard let url = URL(string: "\(config.endpoint)/api/tags") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["name"] as? String }
        } catch {
            return []
        }
    }

    private func buildPrompt(text: String, source: String, target: String) -> String {
        let customPromptTemplate = config.customPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customPromptTemplate.isEmpty {
            return applyTemplate(customPromptTemplate, text: text, source: source, target: target, domain: config.domainInstruction)
        }
        // HY-MT 官方 prompt 模板 + 领域指令
        let isZhInvolved = source.hasPrefix("zh") || target.hasPrefix("zh")
        var parts: [String] = []
        if !config.domainInstruction.isEmpty {
            parts.append(config.domainInstruction)
        }
        if isZhInvolved {
            let targetName = LanguageOption.named(target)?.chineseName ?? target
            parts.append("将以下文本翻译为\(targetName)，注意只需要输出翻译后的结果，不要额外解释：")
        } else {
            let englishName = englishLanguageName(for: target)
            parts.append("Translate the following segment into \(englishName), without additional explanation.")
        }
        parts.append(text)
        return parts.joined(separator: "\n\n")
    }

    private func englishLanguageName(for code: String) -> String {
        let map: [String: String] = [
            "zh-Hans": "Chinese", "zh-Hant": "Traditional Chinese", "zh": "Chinese",
            "en": "English", "ja": "Japanese", "ko": "Korean",
            "it": "Italian", "fr": "French", "de": "German", "es": "Spanish",
            "pt": "Portuguese", "ru": "Russian", "ar": "Arabic"
        ]
        return map[code] ?? code
    }
}

// MARK: - OpenAI 兼容

struct OpenAICompatibleAPI: TranslationAPI {
    let config: TranslationConfig

    func translate(text: String, from source: String, to target: String) async throws -> String {
        let prompt = buildPrompt(text: text, source: source, target: target)

        var systemContent = "You are a professional translator. Translate accurately without adding explanations."
        if !config.domainInstruction.isEmpty {
            systemContent += "\n\n" + config.domainInstruction
        }

        let body: [String: Any] = [
            "model": config.modelID,
        "messages": [
            ["role": "system", "content": systemContent],
            ["role": "user", "content": prompt]
        ],
        "temperature": config.temperature
        ]

        let url = chatCompletionsURL()
        let data = try await postJSON(to: url, body: body, apiKey: config.apiKey)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationAPIError.parseError("OpenAI 响应格式错误")
        }

        return cleanResponse(content)
    }

    func translateBatch(_ items: [BatchTranslationItem], from source: String, to target: String) async throws -> [BatchTranslationResult] {
        try await performOpenAIStyleBatch(config: config, items: items, source: source, target: target)
    }

    func testConnection() async -> Bool {
        // 优先尝试 /models 端点（几乎所有 OpenAI 兼容服务都支持，不消耗 token）
        guard let url = URL(string: "\(config.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/models") else {
            return false
        }
        var request = URLRequest(url: url)
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) {
                return true
            }
        } catch {
            // 降级到真正的翻译调用
        }
        do {
            _ = try await translate(text: "hi", from: "en", to: "zh-Hans")
            return true
        } catch {
            return false
        }
    }

    func listModels() async -> [String] {
        guard let url = URL(string: "\(config.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/models") else { return [] }
        var request = URLRequest(url: url)
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["id"] as? String }
        } catch {
            return []
        }
    }

    private func chatCompletionsURL() -> String {
        openAICompletionsURL(endpoint: config.endpoint)
    }

    private func buildPrompt(text: String, source: String, target: String) -> String {
        let customPromptTemplate = config.customPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customPromptTemplate.isEmpty {
            return applyTemplate(customPromptTemplate, text: text, source: source, target: target, domain: config.domainInstruction)
        }
        let targetName = LanguageOption.named(target)?.name ?? target
        let sourceName = LanguageOption.named(source)?.name ?? source
        return "请将以下\(sourceName)文本翻译为\(targetName)，直接输出译文，不要添加任何说明：\n\n\(text)"
    }
}

// MARK: - 公共工具

private func postJSON(to urlString: String, body: [String: Any], apiKey: String = "") async throws -> Data {
    guard let url = URL(string: urlString) else {
        throw TranslationAPIError.invalidEndpoint
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !apiKey.isEmpty {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 300

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw TranslationAPIError.connectionFailed
    }
    guard (200..<300).contains(http.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? ""
        let snippet = body.prefix(800).replacingOccurrences(of: "\n", with: "\\n")
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "(缺失)"
        throw TranslationAPIError.httpError(http.statusCode, "响应字节 \(data.count)，Content-Type \(contentType)，正文开头：\(snippet)")
    }
    return data
}

func cleanResponse(_ content: String) -> String {
    var result = content.trimmingCharacters(in: .whitespacesAndNewlines)
    result = removeThinkBlocks(from: result)

    // 移除 <target></target>、<translation></translation> 标签
    for tag in ["target", "translation", "output"] {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        if result.hasPrefix(open) && result.hasSuffix(close) {
            result = String(result.dropFirst(open.count).dropLast(close.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // 移除代码块围栏 ```...```
    if result.hasPrefix("```") {
        if let end = result.range(of: "```", options: .backwards), end.lowerBound != result.startIndex {
            var inner = String(result[result.index(after: result.firstIndex(of: "\n") ?? result.startIndex)..<end.lowerBound])
            inner = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty { result = inner }
        }
    }
    result = removeThinkBlocks(from: result)

    // 移除成对包裹的引号
    let quotePairs: [(String, String)] = [("\"", "\""), ("「", "」"), ("“", "”"), ("『", "』")]
    for (o, c) in quotePairs {
        if result.hasPrefix(o) && result.hasSuffix(c) && result.count > o.count + c.count {
            result = String(result.dropFirst(o.count).dropLast(c.count))
        }
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func removeThinkBlocks(from content: String) -> String {
    let pattern = #"<think\b[^>]*>[\s\S]*?</think>"#
    let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    let range = NSRange(content.startIndex..<content.endIndex, in: content)
    return regex?
        .stringByReplacingMatches(in: content, options: [], range: range, withTemplate: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? content.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func applyTemplate(_ template: String, text: String, source: String, target: String, domain: String = "") -> String {
    let targetName = LanguageOption.named(target)?.name ?? target
    let sourceName = LanguageOption.named(source)?.name ?? source
    return template.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "{text}", with: text)
        .replacingOccurrences(of: "{source}", with: sourceName)
        .replacingOccurrences(of: "{target}", with: targetName)
        .replacingOccurrences(of: "{source_code}", with: source)
        .replacingOccurrences(of: "{target_code}", with: target)
        .replacingOccurrences(of: "{domain}", with: domain)
}

// MARK: - 翻译缓存（LRU 上限，避免无限增长）

actor TranslationCache {
    private var cache: [String: String] = [:]
    private var order: [String] = []  // 简易 LRU 顺序追踪
    private let maxEntries: Int

    init(maxEntries: Int = 5000) {
        self.maxEntries = maxEntries
    }

    private func key(_ text: String, _ src: String, _ tgt: String, _ domain: String) -> String {
        "\(src)|\(tgt)|\(domain.hashValue)|\(text)"
    }

    func get(_ text: String, _ src: String, _ tgt: String, _ domain: String = "") -> String? {
        let k = key(text, src, tgt, domain)
        guard let value = cache[k] else { return nil }
        // 提升到末尾
        if let idx = order.firstIndex(of: k) {
            order.remove(at: idx)
            order.append(k)
        }
        return value
    }

    func set(_ text: String, _ src: String, _ tgt: String, _ result: String, _ domain: String = "") {
        // 不缓存空译文（失败结果），避免永久失败
        guard !result.isEmpty else { return }
        let k = key(text, src, tgt, domain)
        if cache[k] == nil {
            order.append(k)
        }
        cache[k] = result
        // LRU 淘汰
        while order.count > maxEntries {
            let old = order.removeFirst()
            cache.removeValue(forKey: old)
        }
    }

    func clear() {
        cache.removeAll()
        order.removeAll()
    }
}

actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) { self.available = value }

    func wait() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { cont in waiters.append(cont) }
    }

    func signal() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            available += 1
        }
    }
}

/// 带缓存、并发控制、去重和重试的批量翻译
func translateTextsBatch(
    texts: [String],
    from source: String,
    to target: String,
    api: TranslationAPI,
    cache: TranslationCache,
    concurrency: Int,
    domainKey: String = ""
) async -> [String] {
    guard !texts.isEmpty else { return [] }

    var results = [String](repeating: "", count: texts.count)

    // 1. 先查缓存；同时对未命中的文本去重（相同文本只调用一次 API）
    var uniqueTexts: [String] = []
    var textToUniqueIdx: [String: Int] = [:]
    // 每个原始索引 → 去重后的索引（或 -1 表示命中缓存）
    var origToUnique: [Int] = Array(repeating: -1, count: texts.count)

    for (i, text) in texts.enumerated() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            results[i] = ""
            continue
        }
        if let cached = await cache.get(trimmed, source, target, domainKey) {
            results[i] = cached
            continue
        }
        if let u = textToUniqueIdx[trimmed] {
            origToUnique[i] = u
        } else {
            let u = uniqueTexts.count
            textToUniqueIdx[trimmed] = u
            uniqueTexts.append(trimmed)
            origToUnique[i] = u
        }
    }

    guard !uniqueTexts.isEmpty else { return results }

    // 2. 并发翻译（失败后重试一次）
    let semaphore = AsyncSemaphore(value: max(1, concurrency))
    var uniqueResults = [String](repeating: "", count: uniqueTexts.count)

    await withTaskGroup(of: (Int, String).self) { group in
        for (idx, text) in uniqueTexts.enumerated() {
            group.addTask {
                await semaphore.wait()
                defer { Task { await semaphore.signal() } }
                // 最多尝试 2 次
                for attempt in 0..<2 {
                    do {
                        let t = try await api.translate(text: text, from: source, to: target)
                        if !t.isEmpty { return (idx, t) }
                    } catch {
                        if attempt == 0 {
                            try? await Task.sleep(nanoseconds: 300_000_000)  // 0.3s 退避
                        }
                    }
                }
                return (idx, "")
            }
        }
        for await (idx, t) in group {
            uniqueResults[idx] = t
        }
    }

    // 3. 回填结果 + 写缓存（空结果不缓存）
    for (i, u) in origToUnique.enumerated() where u >= 0 {
        results[i] = uniqueResults[u]
    }
    for (idx, text) in uniqueTexts.enumerated() where !uniqueResults[idx].isEmpty {
        await cache.set(text, source, target, uniqueResults[idx], domainKey)
    }

    return results
}
// MARK: - 批量请求构造（不执行网络，便于测试）

/// 构造 Ollama / HY-MT 批量请求体。
func buildOllamaBatchBody(
    config: TranslationConfig,
    items: [BatchTranslationItem],
    source: String,
    target: String
) -> [String: Any] {
    let prompt = buildBatchPrompt(items: items, source: source, target: target, domainInstruction: config.domainInstruction, customPromptTemplate: config.customPromptTemplate)
    return [
        "model": config.modelID,
        "messages": [
            ["role": "user", "content": prompt]
        ],
        "stream": false,
        "format": "json",
        "options": [
            "temperature": config.temperature,
            "top_p": 0.6,
            "top_k": 20,
            "repeat_penalty": 1.05
        ]
    ]
}

/// 构造 OpenAI 兼容批量请求体。
func buildOpenAIBatchBody(
    config: TranslationConfig,
    items: [BatchTranslationItem],
    source: String,
    target: String
) -> [String: Any] {
    let prompt = buildBatchPrompt(items: items, source: source, target: target, domainInstruction: config.domainInstruction, customPromptTemplate: config.customPromptTemplate)
    var systemContent = "You are a professional translator. Translate accurately without adding explanations."
    systemContent += " Return exactly one JSON object. Every input id must appear exactly once as an output key, with its translation as the string value."
    if !config.domainInstruction.isEmpty {
        systemContent += "\n\n" + config.domainInstruction
    }
    var body: [String: Any] = [
        "model": config.modelID,
        "messages": [
            ["role": "system", "content": systemContent],
            ["role": "user", "content": prompt]
        ],
        "response_format": ["type": "json_object"],
        "temperature": config.temperature
    ]
    // DeepSeek 思考模式会消耗 max_tokens，可能在生成正式 content 前以 finish_reason=length 结束。
    // 对 DeepSeek 官方端点/模型关闭思考，保证 JSON 译文有可用的输出预算。
    if config.endpoint.localizedCaseInsensitiveContains("deepseek") || config.modelID.localizedCaseInsensitiveContains("deepseek") {
        body["thinking"] = ["type": "disabled"]
    }
    return body
}

/// 生成 OpenAI 兼容 chat/completions 端点。
func openAICompletionsURL(endpoint: String) -> String {
    let trimmed = endpoint
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if trimmed.hasSuffix("/chat/completions") {
        return trimmed
    }
    return "\(trimmed)/chat/completions"
}

/// 构造批量翻译 prompt：要求模型只返回 JSON 对象，并携带稳定 id。
func buildBatchPrompt(items: [BatchTranslationItem], source: String, target: String, domainInstruction: String, customPromptTemplate: String = "") -> String {
    let targetName = LanguageOption.named(target)?.name ?? target
    let sourceName = LanguageOption.named(source)?.name ?? source
    let itemPayload = batchItemsJSON(items)
    let custom = customPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
    if !custom.isEmpty {
        let containsBatchPayload = custom.contains("{items}") || custom.contains("{batch}")
        let rendered = custom
            .replacingOccurrences(of: "{items}", with: itemPayload)
            .replacingOccurrences(of: "{batch}", with: itemPayload)
            .replacingOccurrences(of: "{text}", with: items.map(\.text).joined(separator: "\n"))
            .replacingOccurrences(of: "{source}", with: sourceName)
            .replacingOccurrences(of: "{target}", with: targetName)
            .replacingOccurrences(of: "{source_code}", with: source)
            .replacingOccurrences(of: "{target_code}", with: target)
            .replacingOccurrences(of: "{domain}", with: domainInstruction)
        let payloadSection = containsBatchPayload ? "" : "\n\n批量输入 JSON：\n" + itemPayload
        return rendered + payloadSection + "\n\n只输出一个 JSON 对象。对象的键必须逐一、完整地复制所有输入 id，值为对应译文。不得遗漏、改名或增加键，不要添加解释。"
    }
    var parts: [String] = []
    if !domainInstruction.isEmpty {
        parts.append(domainInstruction)
    }
    parts.append("请将以下 \(sourceName) 文本翻译为 \(targetName)。")
    parts.append("要求：只输出一个 JSON 对象，不要输出代码块围栏、解释或任何额外文字。")
    parts.append("输出对象的键必须逐一、完整地复制所有输入 id，值为对应译文。")
    parts.append("输出示例：{\"p0_b0\": \"译文一\", \"p0_b1\": \"译文二\"}")
    parts.append("不得遗漏、改名、增加或合并任何 id。")
    parts.append("")
    parts.append("待翻译项（必须按 id 返回，原文已使用合法 JSON 转义）：")
    parts.append(itemPayload)
    return parts.joined(separator: "\n")
}

private func batchItemsJSON(_ items: [BatchTranslationItem]) -> String {
    var values: [String: String] = [:]
    for item in items {
        values[item.id] = item.text
    }
    guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]),
          let encoded = String(data: data, encoding: .utf8) else { return "[]" }
    return encoded
}

// MARK: - 批量响应解析与校验

enum BatchTranslationError: Error, LocalizedError {
    case invalidJSON(String)
    case missingID(String)
    case duplicateID(String)
    case unknownID(String)
    case missingTranslation(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let msg): return "批量响应不是合法 JSON: \(msg)"
        case .missingID(let id): return "批量响应遗漏了 id '\(id)' 的译文"
        case .duplicateID(let id): return "批量响应中 id '\(id)' 重复出现"
        case .unknownID(let id): return "批量响应包含未知的 id '\(id)'"
        case .missingTranslation(let id): return "批量响应中 id '\(id)' 缺少译文内容"
        }
    }
}

/// 从模型原始返回（可能带代码围栏/think 块/前导说明）中提取 JSON 子串。
func extractJSONString(from raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    s = removeThinkBlocks(from: s)

    // 移除 ```json ... ``` 代码块围栏
    if s.hasPrefix("```") {
        if let firstNL = s.firstIndex(of: "\n") {
            let innerStart = s.index(after: firstNL)
            if let fenceEnd = s.range(of: "```", options: .backwards), fenceEnd.lowerBound >= innerStart {
                s = String(s[innerStart..<fenceEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    // 整串本身即合法 JSON
    if let d = s.data(using: .utf8), (try? JSONSerialization.jsonObject(with: d)) != nil {
        return s
    }

    // 否则扫描第一个能完整解析的 JSON 子串（跳过前导说明中的括号）
    var idx = s.startIndex
    while idx < s.endIndex {
        let c = s[idx]
        if c == "[" || c == "{" {
            let close: Character = c == "[" ? "]" : "}"
            if let end = matchingJSONClose(from: idx, in: s, open: c, close: close) {
                let candidate = String(s[idx...end])
                if candidate.count >= 2,
                   let d = candidate.data(using: .utf8),
                   (try? JSONSerialization.jsonObject(with: d)) != nil {
                    return candidate
                }
            }
        }
        idx = s.index(after: idx)
    }

    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 找到与 start 处 open 括号配对的 close 括号下标（感知 JSON 字符串与嵌套）。
private func matchingJSONClose(from start: String.Index, in s: String, open: Character, close: Character) -> String.Index? {
    guard s[start] == open else { return nil }
    var expectedClosers: [Character] = [close]
    var inString = false
    var escaped = false
    var i = s.index(after: start)
    while i < s.endIndex {
        let c = s[i]
        if inString {
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                inString = false
            }
        } else {
            if c == "\"" {
                inString = true
            } else if c == "{" {
                expectedClosers.append("}")
            } else if c == "[" {
                expectedClosers.append("]")
            } else if c == "}" || c == "]" {
                guard expectedClosers.last == c else { return nil }
                expectedClosers.removeLast()
                if expectedClosers.isEmpty { return i }
            }
        }
        i = s.index(after: i)
    }
    return nil
}

/// 解析并校验批量响应，返回按输入顺序排列的结果。
func parseBatchTranslations(raw: String, expected: [BatchTranslationItem]) throws -> [BatchTranslationResult] {
    guard !expected.isEmpty else { return [] }

    // 有些模型会输出 JSON Lines / 连续 JSON 对象。旧逻辑只取第一个片段，导致误报“返回 1/期望 N”。
    let fragments = extractJSONFragments(from: raw)
    if fragments.count > 1 {
        let expectedIDs = Set(expected.map(\.id))
        var fragmentPairs: [(id: String, text: String)] = []
        var recognizedAllFragments = true
        for fragment in fragments {
            guard let data = fragment.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                recognizedAllFragments = false
                break
            }
            if let id = dict["id"] as? String,
               let text = translationText(from: dict),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fragmentPairs.append((id, text))
                continue
            }
            let mapped = dict.compactMap { id, value -> (id: String, text: String)? in
                guard expectedIDs.contains(id), let text = translationText(from: value) else { return nil }
                return (id, text)
            }
            if mapped.isEmpty {
                recognizedAllFragments = false
                break
            }
            fragmentPairs.append(contentsOf: mapped)
        }
        if recognizedAllFragments, !fragmentPairs.isEmpty {
            return try validateBatchPairs(fragmentPairs, expected: expected)
        }
    }

    let jsonString = extractJSONString(from: raw)
    guard let data = jsonString.data(using: .utf8) else {
        throw BatchTranslationError.invalidJSON("无法转换为 UTF-8 数据")
    }
    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: data)
    } catch {
        let snippet = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(240)
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        throw BatchTranslationError.invalidJSON("\(error.localizedDescription); 原始响应 \(raw.count) 字符，开头：\(snippet)")
    }

    let pairs: [(id: String, text: String)]
    if let encoded = object as? String, encoded != raw {
        return try parseBatchTranslations(raw: encoded, expected: expected)
    } else if let array = object as? [[String: Any]] {
        pairs = try array.map { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else {
                throw BatchTranslationError.missingID("(条目缺少 id)")
            }
            guard let text = translationText(from: entry),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BatchTranslationError.missingTranslation(id)
            }
            return (id, text)
        }
    } else if let dict = object as? [String: Any],
              let singleID = dict["id"] as? String,
              !singleID.isEmpty {
        guard let text = translationText(from: dict),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BatchTranslationError.missingTranslation(singleID)
        }
        pairs = [(singleID, text)]
    } else if expected.count == 1,
              let dict = object as? [String: Any],
              let text = translationText(from: dict),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        // 某些模型在单项回退时仅返回 {"translation":"..."}，此时映射到唯一的期望 ID 是确定的。
        pairs = [(expected[0].id, text)]
    } else if let dict = object as? [String: Any],
              let nested = dict["translations"] ?? dict["results"] ?? dict["items"],
              let nestedArray = nested as? [[String: Any]] {
        pairs = try nestedArray.map { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else {
                throw BatchTranslationError.missingID("(条目缺少 id)")
            }
            guard let text = translationText(from: entry),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BatchTranslationError.missingTranslation(id)
            }
            return (id, text)
        }
    } else if let dict = object as? [String: Any],
              let nested = dict["translations"] ?? dict["results"] ?? dict["items"],
              let nestedDict = nested as? [String: Any] {
        pairs = try nestedDict.map { (id, value) in
            guard let text = translationText(from: value) else {
                throw BatchTranslationError.missingTranslation(id)
            }
            return (id, text)
        }
    } else if let dict = object as? [String: Any] {
        pairs = try dict.map { (id, value) in
            guard let text = translationText(from: value) else {
                throw BatchTranslationError.missingTranslation(id)
            }
            return (id, text)
        }
    } else {
        throw BatchTranslationError.invalidJSON("根节点必须是 JSON 数组或对象")
    }

    return try validateBatchPairs(pairs, expected: expected)
}

private func extractJSONFragments(from raw: String) -> [String] {
    let content = removeThinkBlocks(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    var fragments: [String] = []
    var index = content.startIndex
    while index < content.endIndex {
        let character = content[index]
        guard character == "[" || character == "{" else {
            index = content.index(after: index)
            continue
        }
        let close: Character = character == "[" ? "]" : "}"
        guard let end = matchingJSONClose(from: index, in: content, open: character, close: close) else {
            index = content.index(after: index)
            continue
        }
        let candidate = String(content[index...end])
        if let data = candidate.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            fragments.append(candidate)
            index = content.index(after: end)
        } else {
            index = content.index(after: index)
        }
    }
    return fragments
}

private func translationText(from entry: [String: Any]) -> String? {
    if let t = entry["translation"] as? String { return t }
    if let t = entry["text"] as? String { return t }
    if let t = entry["translated"] as? String { return t }
    if let t = entry["translated_text"] as? String { return t }
    if let t = entry["target"] as? String { return t }
    if let t = entry["value"] as? String { return t }
    return nil
}

private func translationText(from value: Any) -> String? {
    if let s = value as? String { return s }
    if let sub = value as? [String: Any] { return translationText(from: sub) }
    return nil
}

/// 校验响应中的 id 集合（缺失/重复/未知），并按输入顺序返回结果。
private func validateBatchPairs(_ pairs: [(id: String, text: String)], expected: [BatchTranslationItem]) throws -> [BatchTranslationResult] {
    let expectedSet = Set(expected.map(\.id))
    var seen = Set<String>()
    var byID: [String: String] = [:]
    for (id, text) in pairs {
        if seen.contains(id) {
            throw BatchTranslationError.duplicateID(id)
        }
        seen.insert(id)
        guard expectedSet.contains(id) else {
            throw BatchTranslationError.unknownID(id)
        }
        byID[id] = text
    }
    var results: [BatchTranslationResult] = []
    results.reserveCapacity(expected.count)
    let missing = expected.filter { byID[$0.id] == nil }.map(\.id)
    if !missing.isEmpty {
        throw BatchTranslationError.missingID("\(missing.joined(separator: ","))（返回 \(seen.count)/期望 \(expected.count) 项）")
    }
    for item in expected {
        guard let text = byID[item.id] else { continue }
        results.append(BatchTranslationResult(id: item.id, text: text))
    }
    return results
}

// MARK: - 批量请求发送

private func performOllamaStyleBatch(
    config: TranslationConfig,
    items: [BatchTranslationItem],
    source: String,
    target: String
) async throws -> [BatchTranslationResult] {
    guard !items.isEmpty else { return [] }
    let body = buildOllamaBatchBody(config: config, items: items, source: source, target: target)
    let data = try await postJSON(to: "\(config.endpoint)/api/chat", body: body)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let message = json["message"] as? [String: Any],
          let content = message["content"] as? String else {
        throw TranslationAPIError.parseError("批量响应格式错误；" + responseDiagnostic(data: data))
    }
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TranslationAPIError.emptyContent(responseDiagnostic(data: data))
    }
    return try parseBatchTranslations(raw: content, expected: items)
}

private func performOpenAIStyleBatch(
    config: TranslationConfig,
    items: [BatchTranslationItem],
    source: String,
    target: String
) async throws -> [BatchTranslationResult] {
    guard !items.isEmpty else { return [] }
    let body = buildOpenAIBatchBody(config: config, items: items, source: source, target: target)
    let url = openAICompletionsURL(endpoint: config.endpoint)
    let data = try await postJSON(to: url, body: body, apiKey: config.apiKey)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = json["choices"] as? [[String: Any]],
          let firstChoice = choices.first,
          let message = firstChoice["message"] as? [String: Any] else {
        throw TranslationAPIError.parseError("OpenAI 批量响应格式错误；" + responseDiagnostic(data: data))
    }
    let content = message["content"] as? String ?? ""
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        let reasoningCount = (message["reasoning_content"] as? String)?.count ?? 0
        throw TranslationAPIError.emptyContent(responseDiagnostic(data: data) + "；message.content 字符 0；reasoning_content 字符 \(reasoningCount)")
    }
    return try parseBatchTranslations(raw: content, expected: items)
}

private func responseDiagnostic(data: Data) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return "HTTP 响应字节 \(data.count)，响应体不是可解析 JSON"
    }
    let topKeys = object.keys.sorted().joined(separator: ",")
    let choices = object["choices"] as? [[String: Any]]
    let choice = choices?.first
    let finishReason = choice?["finish_reason"] as? String ?? "(无)"
    let message = choice?["message"] as? [String: Any]
    let messageKeys = message?.keys.sorted().joined(separator: ",") ?? "(无)"
    let contentType = message?["content"].map { String(describing: type(of: $0)) } ?? "(缺失)"
    let usage = object["usage"] as? [String: Any]
    let promptTokens = usage?["prompt_tokens"].map { String(describing: $0) } ?? "(无)"
    let completionTokens = usage?["completion_tokens"].map { String(describing: $0) } ?? "(无)"
    let totalTokens = usage?["total_tokens"].map { String(describing: $0) } ?? "(无)"
    return "HTTP 响应字节 \(data.count)；顶层字段 [\(topKeys)]；finish_reason=\(finishReason)；message 字段 [\(messageKeys)]；content 类型=\(contentType)；usage prompt/completion/total=\(promptTokens)/\(completionTokens)/\(totalTokens)"
}
