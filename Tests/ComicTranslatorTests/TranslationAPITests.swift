import XCTest
@testable import ComicTranslator

// MARK: - 批量响应解析与校验

final class BatchTranslationParsingTests: XCTestCase {

    // 稳定 id：同一文本产生相同 id
    func testStableIDDeterministic() {
        let id1 = BatchTranslationItem.stableID(for: "こんにちは")
        let id2 = BatchTranslationItem.stableID(for: "こんにちは")
        XCTAssertEqual(id1, id2)
        XCTAssertNotEqual(id1, BatchTranslationItem.stableID(for: "ありがとう"))
        // 同文本通过便捷构造器生成的 id 一致
        XCTAssertEqual(BatchTranslationItem(text: "abc").id, BatchTranslationItem(text: "abc").id)
        // id 为 JSON 安全字符（不含引号/控制字符）
        XCTAssertFalse(id1.contains("\""))
        XCTAssertFalse(id1.contains("\n"))
    }

    // 乱序返回可正确解析，结果按输入顺序排列
    func testParsesArrayOutOfOrderIntoInputOrder() throws {
        let expected = [
            BatchTranslationItem(id: "a", text: "hello"),
            BatchTranslationItem(id: "b", text: "world"),
            BatchTranslationItem(id: "c", text: "foo"),
        ]
        let raw = #"""
        [{"id":"c","translation":"foobar"},{"id":"a","translation":"nihao"},{"id":"b","translation":"shijie"}]
        """#
        let results = try parseBatchTranslations(raw: raw, expected: expected)
        XCTAssertEqual(results.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(results.map(\.text), ["nihao", "shijie", "foobar"])
    }

    // 对象映射格式 {id: 译文}
    func testParsesObjectDictFormat() throws {
        let expected = [
            BatchTranslationItem(id: "a", text: "x"),
            BatchTranslationItem(id: "b", text: "y"),
        ]
        let raw = #"""{ "a": "xx", "b": "yy" }"""#
        let results = try parseBatchTranslations(raw: raw, expected: expected)
        XCTAssertEqual(results.map(\.id), ["a", "b"])
        XCTAssertEqual(results.map(\.text), ["xx", "yy"])
    }

    // 缺失 id -> recognizable error
    func testMissingIDThrows() {
        let expected = [
            BatchTranslationItem(id: "a", text: "x"),
            BatchTranslationItem(id: "b", text: "y"),
        ]
        let raw = #"""[{"id":"a","translation":"xx"}]"""#
        XCTAssertThrowsError(try parseBatchTranslations(raw: raw, expected: expected)) { error in
            guard case BatchTranslationError.missingID(let id) = error else {
                return XCTFail("expected missingID, got \(error)")
            }
            XCTAssertTrue(id.contains("b"))
        }
    }

    // 重复 id -> recognizable error
    func testDuplicateIDThrows() {
        let expected = [BatchTranslationItem(id: "a", text: "x")]
        let raw = #"""[{"id":"a","translation":"one"},{"id":"a","translation":"two"}]"""#
        XCTAssertThrowsError(try parseBatchTranslations(raw: raw, expected: expected)) { error in
            guard case BatchTranslationError.duplicateID = error else {
                return XCTFail("expected duplicateID, got \(error)")
            }
        }
    }

    // 未知 id -> recognizable error
    func testUnknownIDThrows() {
        let expected = [BatchTranslationItem(id: "a", text: "x")]
        let raw = #"""[{"id":"a","translation":"xx"},{"id":"zzz","translation":"bad"}]"""#
        XCTAssertThrowsError(try parseBatchTranslations(raw: raw, expected: expected)) { error in
            guard case BatchTranslationError.unknownID(let id) = error else {
                return XCTFail("expected unknownID, got \(error)")
            }
            XCTAssertEqual(id, "zzz")
        }
    }

    // 缺少译文内容 -> recognizable error
    func testMissingTranslationThrows() {
        let expected = [BatchTranslationItem(id: "a", text: "x")]
        let raw = #"""[{"id":"a"}]"""#
        XCTAssertThrowsError(try parseBatchTranslations(raw: raw, expected: expected)) { error in
            guard case BatchTranslationError.missingTranslation(let id) = error else {
                return XCTFail("expected missingTranslation, got \(error)")
            }
            XCTAssertEqual(id, "a")
        }
    }

    // 非法 JSON -> recognizable error
    func testInvalidJSONThrows() {
        let expected = [BatchTranslationItem(id: "a", text: "x")]
        let raw = "这是纯文本，没有 JSON"
        XCTAssertThrowsError(try parseBatchTranslations(raw: raw, expected: expected)) { error in
            guard case BatchTranslationError.invalidJSON = error else {
                return XCTFail("expected invalidJSON, got \(error)")
            }
        }
    }

    // 空输入 -> 空结果（不抛错）
    func testEmptyInputReturnsEmpty() throws {
        let results = try parseBatchTranslations(raw: "whatever", expected: [])
        XCTAssertTrue(results.isEmpty)
    }

    // 响应清理：think 块 + 代码块围栏
    func testCleansCodeFenceAndThinkBlock() throws {
        let expected = [BatchTranslationItem(id: "a", text: "x")]
        let raw = """
        <think>思考中...</think>
        ```json
        [{"id":"a","translation":"译文"}]
        ```
        """
        let results = try parseBatchTranslations(raw: raw, expected: expected)
        XCTAssertEqual(results.first?.text, "译文")
    }

    // 响应清理：前导说明文字中的括号不会干扰真正的 JSON
    func testCleansPrefixedSentence() throws {
        let expected = [BatchTranslationItem(id: "a", text: "x")]
        let raw = #"翻译结果如下：[{"id":"a","translation":"你好"}]"#
        let results = try parseBatchTranslations(raw: raw, expected: expected)
        XCTAssertEqual(results.first?.text, "你好")
    }

    // extractJSONString：字符串内部的括号不应被误判为边界
    func testExtractJSONHandlesNestedBracketsInString() {
        let raw = #"[{"id":"a","translation":"包含 ] 和 } 的译文"}]"#
        let extracted = extractJSONString(from: raw)
        XCTAssertEqual(extracted, raw)
    }

    func testParsesTranslationsWrapperObject() throws {
        let expected = [BatchTranslationItem(id: "a", text: "x")]
        let raw = #"{"translations":[{"id":"a","translation":"译文"}]}"#
        let results = try parseBatchTranslations(raw: raw, expected: expected)
        XCTAssertEqual(results.first?.text, "译文")
    }

    func testParsesSingleTranslationObject() throws {
        let expected = [BatchTranslationItem(id: "a", text: "x")]
        let raw = #"{"id":"a","translation":"译文"}"#
        let results = try parseBatchTranslations(raw: raw, expected: expected)
        XCTAssertEqual(results.first?.text, "译文")
    }

    func testSingleTranslationObjectWithEmptyContentThrowsSpecificID() {
        let expected = [BatchTranslationItem(id: "a", text: "x")]
        let raw = #"{"id":"a","translation":""}"#
        XCTAssertThrowsError(try parseBatchTranslations(raw: raw, expected: expected)) { error in
            guard case BatchTranslationError.missingTranslation(let id) = error else {
                return XCTFail("expected missingTranslation, got \(error)")
            }
            XCTAssertEqual(id, "a")
        }
    }

    func testSingleTranslationWithoutIDMapsToOnlyExpectedItem() throws {
        let expected = [BatchTranslationItem(id: "p55_b3", text: "x")]
        let raw = #"{"translation":"译文"}"#
        let results = try parseBatchTranslations(raw: raw, expected: expected)
        XCTAssertEqual(results.first?.id, "p55_b3")
        XCTAssertEqual(results.first?.text, "译文")
    }

    func testParsesJSONLinesWithoutDroppingLaterItems() throws {
        let expected = [
            BatchTranslationItem(id: "a", text: "x"),
            BatchTranslationItem(id: "b", text: "y"),
        ]
        let raw = """
        {"id":"a","translation":"译文一"}
        {"id":"b","translation":"译文二"}
        """
        let results = try parseBatchTranslations(raw: raw, expected: expected)
        XCTAssertEqual(results.map(\.text), ["译文一", "译文二"])
    }

    func testParsesConcatenatedIDMaps() throws {
        let expected = [
            BatchTranslationItem(id: "a", text: "x"),
            BatchTranslationItem(id: "b", text: "y"),
        ]
        let raw = #"{"a":"译文一"}{"b":"译文二"}"#
        let results = try parseBatchTranslations(raw: raw, expected: expected)
        XCTAssertEqual(results.map(\.text), ["译文一", "译文二"])
    }

    func testParsesDoubleEncodedJSON() throws {
        let expected = [BatchTranslationItem(id: "a", text: "x")]
        let raw = #""[{"id":"a","translation":"译文"}]""#
        let results = try parseBatchTranslations(raw: raw, expected: expected)
        XCTAssertEqual(results.first?.text, "译文")
    }
}

// MARK: - 批量请求构造

final class BatchRequestBuildingTests: XCTestCase {

    private let config = TranslationConfig(
        endpoint: "http://localhost:11434",
        apiKey: "",
        modelID: "test-model",
        temperature: 0.3,
        customPromptTemplate: "",
        domainInstruction: "这是领域指令"
    )

    func testOllamaBatchBodyUsesJSONFormatAndIds() {
        let items = [
            BatchTranslationItem(id: "a", text: "x"),
            BatchTranslationItem(id: "b", text: "y"),
        ]
        let body = buildOllamaBatchBody(config: config, items: items, source: "ja", target: "zh-Hans")
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["format"] as? String, "json")
        XCTAssertEqual(body["stream"] as? Bool, false)
        let messages = body["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.first?["role"] as? String, "user")
        let content = messages?.first?["content"] as? String ?? ""
        XCTAssertTrue(content.contains("\"a\""))
        XCTAssertTrue(content.contains("\"b\""))
        XCTAssertTrue(content.contains("JSON"))
    }

    func testOpenAIBatchBodyHasSystemAndUserMessages() {
        let openAIConfig = TranslationConfig(
            endpoint: "https://api.deepseek.com/v1",
            apiKey: "",
            modelID: "deepseek-chat",
            temperature: 0.2,
            customPromptTemplate: "",
            domainInstruction: "领域"
        )
        let items = [BatchTranslationItem(id: "a", text: "x")]
        let body = buildOpenAIBatchBody(config: openAIConfig, items: items, source: "ja", target: "zh-Hans")
        let messages = body["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?[0]["role"] as? String, "system")
        XCTAssertEqual(messages?[1]["role"] as? String, "user")
        XCTAssertTrue((messages?[1]["content"] as? String ?? "").contains("\"a\""))
        XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
    }

    func testBuildBatchPromptIncludesIdsAndJSONInstruction() {
        let items = [
            BatchTranslationItem(id: "a", text: "x"),
            BatchTranslationItem(id: "b", text: "y"),
        ]
        let prompt = buildBatchPrompt(items: items, source: "ja", target: "zh-Hans", domainInstruction: "这是领域指令")
        XCTAssertTrue(prompt.contains("\"a\""))
        XCTAssertTrue(prompt.contains("\"b\""))
        XCTAssertTrue(prompt.contains("JSON"))
        XCTAssertTrue(prompt.contains("这是领域指令"))
    }

    func testCustomBatchPromptUsesItemsPlaceholderAndEscapesText() {
        let customConfig = TranslationConfig(
            endpoint: "http://localhost:11434",
            apiKey: "",
            modelID: "test-model",
            temperature: 0.3,
            customPromptTemplate: "按我的风格处理：{items}",
            domainInstruction: ""
        )
        let items = [BatchTranslationItem(id: "p0_b0", text: "他说\"你好\"\n下一行")]
        let body = buildOllamaBatchBody(config: customConfig, items: items, source: "ja", target: "zh-Hans")
        let messages = body["messages"] as? [[String: Any]]
        let content = messages?.first?["content"] as? String ?? ""
        XCTAssertTrue(content.contains("按我的风格处理"))
        XCTAssertTrue(content.contains("p0_b0"))
        XCTAssertTrue(content.contains("\\\"你好\\\""))
        XCTAssertTrue(content.contains("对象的键"))
    }

    func testCustomTextOnlyPromptStillIncludesBatchIDs() {
        let customConfig = TranslationConfig(
            endpoint: "https://api.deepseek.com/v1",
            apiKey: "",
            modelID: "deepseek-chat",
            temperature: 0.3,
            customPromptTemplate: "请翻译：{text}",
            domainInstruction: ""
        )
        let items = [BatchTranslationItem(id: "p8_b1", text: "原文")]
        let body = buildOpenAIBatchBody(config: customConfig, items: items, source: "ja", target: "zh-Hans")
        let messages = body["messages"] as? [[String: Any]]
        let content = messages?.last?["content"] as? String ?? ""
        XCTAssertTrue(content.contains("批量输入 JSON"))
        XCTAssertTrue(content.contains("p8_b1"))
    }

    func testBatchBodyDoesNotImposeClientTokenLimit() {
        let items = [BatchTranslationItem(id: "a", text: String(repeating: "较长文本 ", count: 500))]
        let ollamaBody = buildOllamaBatchBody(config: config, items: items, source: "ja", target: "zh-Hans")
        let openAIBody = buildOpenAIBatchBody(config: config, items: items, source: "ja", target: "zh-Hans")
        XCTAssertNil(ollamaBody["num_predict"])
        XCTAssertNil(openAIBody["max_tokens"])
    }

    func testOpenAICompletionsURLNormalization() {
        XCTAssertEqual(openAICompletionsURL(endpoint: "https://api.openai.com/v1"),
                       "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(openAICompletionsURL(endpoint: "https://api.openai.com/v1/"),
                       "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(openAICompletionsURL(endpoint: "https://x.com/v1/chat/completions"),
                       "https://x.com/v1/chat/completions")
    }
}

// MARK: - 默认 translateBatch 实现（兼容回退）

final class DefaultTranslateBatchTests: XCTestCase {

    func testDefaultTranslateBatchFallsBackToTranslate() async throws {
        let api = StubTranslationAPI()
        let items = [
            BatchTranslationItem(id: "a", text: "x"),
            BatchTranslationItem(id: "b", text: "y"),
        ]
        let results = try await api.translateBatch(items, from: "ja", to: "zh-Hans")
        XCTAssertEqual(results.map(\.id), ["a", "b"])
        XCTAssertEqual(results.map(\.text), ["x-translated", "y-translated"])
    }

    func testDefaultTranslateBatchEmptyInputReturnsEmpty() async throws {
        let api = StubTranslationAPI()
        let results = try await api.translateBatch([], from: "ja", to: "zh-Hans")
        XCTAssertTrue(results.isEmpty)
    }
}

// MARK: - 三个后端在协议层面具备批量能力（编译期校验）

final class BackendConformanceTests: XCTestCase {

    func testAllBackendsExposeTranslateBatch() {
        let config = TranslationConfig(
            endpoint: "http://localhost:11434",
            apiKey: "",
            modelID: "test",
            temperature: 0.0,
            customPromptTemplate: "",
            domainInstruction: ""
        )
        let apis: [any TranslationAPI] = [
            OllamaAPI(config: config),
            HYMTAPI(config: config),
            OpenAICompatibleAPI(config: config),
        ]
        XCTAssertEqual(apis.count, 3)
    }
}

// 用于验证默认 translateBatch 回退实现的测试桩
private struct StubTranslationAPI: TranslationAPI {
    func translate(text: String, from source: String, to target: String) async throws -> String {
        text + "-translated"
    }
    func testConnection() async -> Bool { true }
    func listModels() async -> [String] { [] }
}
