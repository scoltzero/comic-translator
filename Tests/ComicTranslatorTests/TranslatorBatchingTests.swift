import XCTest
@testable import ComicTranslator

// MARK: - 跨页批量翻译的纯 helper 测试
//
// 这些测试聚焦于去重/回填计划（pageID/blockID 映射、缓存命中）与批量重试逻辑，
// 不依赖 OCR / 真实图片，因此可独立运行。

/// 记录 API 调用次数的线程安全计数器。
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0

    func record() -> Int {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
        return _calls
    }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
}

/// 第一次批量调用失败、随后成功的测试桩。
private struct FlakyBatchAPI: TranslationAPI {
    let counter: CallCounter

    func translate(text: String, from source: String, to target: String) async throws -> String {
        text
    }

    func translateBatch(_ items: [BatchTranslationItem], from source: String, to target: String) async throws -> [BatchTranslationResult] {
        if counter.record() == 1 {
            throw BatchTranslationError.invalidJSON("首次失败")
        }
        return items.map { BatchTranslationResult(id: $0.id, text: $0.text + "-t") }
    }

    func testConnection() async -> Bool { true }
    func listModels() async -> [String] { [] }
}

/// 每次都失败的测试桩。
private struct AlwaysFailBatchAPI: TranslationAPI {
    let counter: CallCounter

    func translate(text: String, from source: String, to target: String) async throws -> String {
        text
    }

    func translateBatch(_ items: [BatchTranslationItem], from source: String, to target: String) async throws -> [BatchTranslationResult] {
        _ = counter.record()
        throw BatchTranslationError.invalidJSON("总是失败")
    }

    func testConnection() async -> Bool { true }
    func listModels() async -> [String] { [] }
}

final class TranslatorBatchingTests: XCTestCase {

    // MARK: - 自适应分批示例

    func testN6W4B8_splitsIntoFourBatches_2_2_1_1() {
        let sizes = BatchPlanner.planPageIndices(pageCount: 6, concurrency: 4, maxPagesPerBatch: 8).map(\.count)
        XCTAssertEqual(sizes, [2, 2, 1, 1])
        XCTAssertEqual(BatchPlanner.batchCount(pageCount: 6, concurrency: 4, maxPagesPerBatch: 8), 4)
    }

    func testN20W4_splitsIntoEvenFourBatches_5_5_5_5() {
        let sizes = BatchPlanner.planPageIndices(pageCount: 20, concurrency: 4, maxPagesPerBatch: 8).map(\.count)
        XCTAssertEqual(sizes, [5, 5, 5, 5])
    }

    func testN40W4_atLeastFiveBatchesEachNoMoreThan8() {
        let ranges = BatchPlanner.planBatches(pageCount: 40, concurrency: 4, maxPagesPerBatch: 8)
        XCTAssertGreaterThanOrEqual(ranges.count, 5)
        for r in ranges {
            XCTAssertLessThanOrEqual(r.count, 8)
        }
    }

    // MARK: - pageID/blockID 映射

    /// pageID/blockID 必须是 页面索引 + 块索引 组成的唯一 ID，不能只用文本 hash。
    func testBuildBlockPlan_usesPageAndBlockIndexForIDs() {
        let blocks = [
            ComicTranslator.BlockEntry(pageIndex: 0, blockIndex: 0, text: "hello"),
            ComicTranslator.BlockEntry(pageIndex: 2, blockIndex: 5, text: "world"),
            ComicTranslator.BlockEntry(pageIndex: 1, blockIndex: 3, text: "foo"),
        ]
        let plan = ComicTranslator.buildBlockPlan(blocks: blocks, cached: [:])
        XCTAssertEqual(plan.items.map(\.id), ["p0_b0", "p2_b5", "p1_b3"])
        XCTAssertEqual(plan.items.map(\.text), ["hello", "world", "foo"])
    }

    /// 同文本跨页去重：只生成一个请求项，结果回填所有引用。
    func testBuildBlockPlan_deduplicatesSameTextAcrossPages() {
        let blocks = [
            ComicTranslator.BlockEntry(pageIndex: 0, blockIndex: 0, text: "同文本"),
            ComicTranslator.BlockEntry(pageIndex: 2, blockIndex: 5, text: "同文本"),
            ComicTranslator.BlockEntry(pageIndex: 1, blockIndex: 0, text: "其它"),
        ]
        let plan = ComicTranslator.buildBlockPlan(blocks: blocks, cached: [:])
        XCTAssertEqual(plan.items.count, 2)
        // 代表 id 取首次出现
        XCTAssertEqual(plan.items.first?.id, "p0_b0")
        XCTAssertEqual(plan.items.first?.text, "同文本")
        // 两个引用都挂在同一个 repID 下
        XCTAssertEqual(plan.repIDToRefs["p0_b0"]?.count, 2)
        XCTAssertEqual(plan.repIDToRefs["p0_b0"]?.map(\.pageIndex), [0, 2])
        XCTAssertEqual(plan.repIDToRefs["p0_b0"]?.map(\.blockIndex), [0, 5])
    }

    /// 命中缓存的文本直接回填，不再发起请求。
    func testBuildBlockPlan_usesCacheDirectly() {
        let blocks = [
            ComicTranslator.BlockEntry(pageIndex: 0, blockIndex: 0, text: "cached"),
            ComicTranslator.BlockEntry(pageIndex: 1, blockIndex: 0, text: "uncached"),
        ]
        let plan = ComicTranslator.buildBlockPlan(blocks: blocks, cached: ["cached": "已缓存译文"])
        XCTAssertEqual(plan.cachedBackfills.count, 1)
        XCTAssertEqual(plan.cachedBackfills[0].pageIndex, 0)
        XCTAssertEqual(plan.cachedBackfills[0].blockIndex, 0)
        XCTAssertEqual(plan.cachedBackfills[0].translation, "已缓存译文")
        XCTAssertEqual(plan.items.map(\.id), ["p1_b0"])
    }

    /// 空白文本不应生成请求项。
    func testBuildBlockPlan_skipsBlankText() {
        let blocks = [
            ComicTranslator.BlockEntry(pageIndex: 3, blockIndex: 2, text: "   \n  "),
            ComicTranslator.BlockEntry(pageIndex: 0, blockIndex: 1, text: "ok"),
        ]
        let plan = ComicTranslator.buildBlockPlan(blocks: blocks, cached: [:])
        XCTAssertEqual(plan.items.map(\.id), ["p0_b1"])
        XCTAssertTrue(plan.cachedBackfills.isEmpty)
    }

    // MARK: - 批量请求重试

    func testRequestBatchWithRetry_failsOnceThenSucceeds() async throws {
        let counter = CallCounter()
        let api = FlakyBatchAPI(counter: counter)
        let items = [BatchTranslationItem(id: "a", text: "x")]
        let results = try await ComicTranslator.requestBatchWithRetry(api: api, items: items, source: "ja", target: "zh-Hans")
        XCTAssertEqual(results.map(\.id), ["a"])
        XCTAssertEqual(results.first?.text, "x-t")
        XCTAssertEqual(counter.calls, 2, "应恰好请求两次：一次失败 + 一次成功")
    }

    func testRequestBatchWithRetry_throwsWhenBothAttemptsFail() async {
        let counter = CallCounter()
        let api = AlwaysFailBatchAPI(counter: counter)
        let items = [BatchTranslationItem(id: "a", text: "x")]
        do {
            _ = try await ComicTranslator.requestBatchWithRetry(api: api, items: items, source: "ja", target: "zh-Hans")
            XCTFail("两次都失败时应抛出")
        } catch {
            // 预期抛出
        }
        XCTAssertEqual(counter.calls, 2, "应恰好请求两次")
    }
}
