import XCTest
@testable import ComicTranslator

final class BatchPlannerTests: XCTestCase {

    // MARK: - 核心示例

    func testN6W4B8_returnsExactlyFourBatchesSize2_2_1_1() {
        let indices = BatchPlanner.planPageIndices(pageCount: 6, concurrency: 4, maxPagesPerBatch: 8)
        XCTAssertEqual(indices, [[0, 1], [2, 3], [4], [5]])
        XCTAssertEqual(indices.map(\.count), [2, 2, 1, 1])
        XCTAssertEqual(BatchPlanner.batchCount(pageCount: 6, concurrency: 4, maxPagesPerBatch: 8), 4)
    }

    func testN20W4_returnsFourEvenBatchesSize5() {
        let indices = BatchPlanner.planPageIndices(pageCount: 20, concurrency: 4, maxPagesPerBatch: 8)
        XCTAssertEqual(indices.map(\.count), [5, 5, 5, 5])
        XCTAssertEqual(BatchPlanner.batchCount(pageCount: 20, concurrency: 4, maxPagesPerBatch: 8), 4)
    }

    func testN40W4_returnsAtLeastFiveBatchesEachNoMoreThan8() {
        let ranges = BatchPlanner.planBatches(pageCount: 40, concurrency: 4, maxPagesPerBatch: 8)
        XCTAssertGreaterThanOrEqual(ranges.count, 5)
        for r in ranges {
            XCTAssertLessThanOrEqual(r.count, 8)
        }
    }

    // MARK: - 边界

    func testZeroPagesReturnsEmpty() {
        XCTAssertEqual(BatchPlanner.planBatches(pageCount: 0, concurrency: 4), [])
        XCTAssertEqual(BatchPlanner.planPageIndices(pageCount: 0, concurrency: 4), [])
        XCTAssertEqual(BatchPlanner.batchCount(pageCount: 0, concurrency: 4), 0)
    }

    func testConcurrencyGreaterThanPageCount() {
        // W > N：批次数受 N 限制，每批 1 页
        let ranges = BatchPlanner.planBatches(pageCount: 3, concurrency: 10, maxPagesPerBatch: 8)
        XCTAssertEqual(ranges.map(\.count), [1, 1, 1])
        XCTAssertEqual(BatchPlanner.batchCount(pageCount: 3, concurrency: 10, maxPagesPerBatch: 8), 3)
    }

    func testConcurrencyOne() {
        // W = 1：单批容纳全部页（不超上限时）
        let ranges = BatchPlanner.planBatches(pageCount: 5, concurrency: 1, maxPagesPerBatch: 8)
        XCTAssertEqual(ranges.map(\.count), [5])
    }

    func testMaxPagesPerBatchOne() {
        // B = 1：每批必须恰好 1 页
        let indices = BatchPlanner.planPageIndices(pageCount: 5, concurrency: 4, maxPagesPerBatch: 1)
        XCTAssertEqual(indices, [[0], [1], [2], [3], [4]])
        XCTAssertEqual(indices.map(\.count), [1, 1, 1, 1, 1])
    }

    func testDefaultMaxPagesPerBatchIsEight() {
        // 不传 B 时默认 8：N=10,W=3 应得 3 批（min(W,N)=3, ceil(10/8)=2 -> 3）
        let ranges = BatchPlanner.planBatches(pageCount: 10, concurrency: 3)
        XCTAssertEqual(ranges.count, 3)
        for r in ranges {
            XCTAssertLessThanOrEqual(r.count, 8)
        }
    }

    func testSinglePage() {
        let ranges = BatchPlanner.planBatches(pageCount: 1, concurrency: 4, maxPagesPerBatch: 8)
        XCTAssertEqual(ranges.map(\.count), [1])
        XCTAssertEqual(ranges.first, 0..<1)
        // W=0 应被钳制到 1，仍返回 1 批
        let zeroConcurrency = BatchPlanner.planBatches(pageCount: 1, concurrency: 0, maxPagesPerBatch: 8)
        XCTAssertEqual(zeroConcurrency.map(\.count), [1])
    }

    // MARK: - 统一性、覆盖性与上限

    func testAllBatchesRespectCapAndCoverAllPages() {
        let cases: [(Int, Int, Int)] = [
            (0, 4, 8), (1, 1, 8), (6, 4, 8), (20, 4, 8), (40, 4, 8),
            (7, 3, 2), (13, 5, 3), (100, 16, 8), (33, 2, 8), (1, 0, 8),
            (5, 4, 1), (9, 2, 1), (25, 1, 8), (11, 6, 4)
        ]
        for (n, w, b) in cases {
            let ranges = BatchPlanner.planBatches(pageCount: n, concurrency: w, maxPagesPerBatch: b)
            if n == 0 {
                XCTAssertTrue(ranges.isEmpty, "N=0 应返回空，got \(ranges)")
                continue
            }
            // 每批不超上限
            for r in ranges {
                XCTAssertLessThanOrEqual(r.count, b, "batch \(r) exceeds cap \(b) for N=\(n) W=\(w) B=\(b)")
            }
            // 覆盖 0..<N，无重复无遗漏
            var seen: [Bool] = Array(repeating: false, count: n)
            var expectedCount = 0
            for r in ranges {
                for page in r {
                    XCTAssertTrue(page >= 0 && page < n, "page index \(page) out of range for N=\(n)")
                    XCTAssertFalse(seen[page], "duplicate page \(page) for N=\(n)")
                    seen[page] = true
                    expectedCount += 1
                }
            }
            XCTAssertEqual(expectedCount, n, "coverage mismatch for N=\(n)")
            XCTAssertEqual(BatchPlanner.planPageIndices(pageCount: n, concurrency: w, maxPagesPerBatch: b)
                .flatMap { $0 }, Array(0..<n), "order/coverage mismatch for N=\(n)")
        }
    }

    func testBatchCountFormula() {
        XCTAssertEqual(BatchPlanner.batchCount(pageCount: 6, concurrency: 4, maxPagesPerBatch: 8), 4)
        XCTAssertEqual(BatchPlanner.batchCount(pageCount: 20, concurrency: 4, maxPagesPerBatch: 8), 4)
        XCTAssertEqual(BatchPlanner.batchCount(pageCount: 40, concurrency: 4, maxPagesPerBatch: 8), 5)
        XCTAssertEqual(BatchPlanner.batchCount(pageCount: 0, concurrency: 4), 0)
        // ceil(8/8)=1 且 min(4,8)=4 -> 4
        XCTAssertEqual(BatchPlanner.batchCount(pageCount: 8, concurrency: 4, maxPagesPerBatch: 8), 4)
        // ceil(9/8)=2 且 min(4,9)=4 -> 4
        XCTAssertEqual(BatchPlanner.batchCount(pageCount: 9, concurrency: 4, maxPagesPerBatch: 8), 4)
    }

    // MARK: - 预算拆分

    func testSplitByBudgetPreservesOrder() {
        let items = ["a", "bb", "ccc", "dddd", "eeeee"]
        let groups = BatchPlanner.splitTextByUTF8Budget(items, budget: 5)
        XCTAssertEqual(groups.flatMap { $0 }, items, "拆分不得改变顺序")
        for g in groups {
            XCTAssertLessThanOrEqual(g.reduce(0) { $0 + $1.utf8.count }, 5, "子组超过预算: \(g)")
        }
    }

    func testSplitByBudgetEmptyInput() {
        XCTAssertEqual(BatchPlanner.splitByBudget([Int](), weight: { $0 }, budget: 5), [])
        XCTAssertEqual(BatchPlanner.splitTextByUTF8Budget([], budget: 5), [])
    }

    func testSplitByBudgetSingleItemOverflow() {
        // 单个元素超预算时独占一组，不能被拆分
        let items = ["abcdef", "x"] // 6 字符 > 5
        let groups = BatchPlanner.splitTextByUTF8Budget(items, budget: 5)
        XCTAssertEqual(groups, [["abcdef"], ["x"]])
    }

    func testSplitByBudgetNonPositiveBudget() {
        // budget <= 0：每个元素一组，避免死循环
        let items = ["a", "bb", "ccc"]
        let groups = BatchPlanner.splitByBudget(items, weight: { $0.count }, budget: 0)
        XCTAssertEqual(groups, [["a"], ["bb"], ["ccc"]])
    }

    func testSplitByBudgetGreedyRuns() {
        let weights = [3, 2, 4, 1, 5, 2]
        let groups = BatchPlanner.splitByBudget(weights, weight: { $0 }, budget: 5)
        // 3+2=5 -> [3,2]; 4 -> ... 4+1=5 -> [4,1]; 5 -> [5]; 2 -> [2]
        XCTAssertEqual(groups, [[3, 2], [4, 1], [5], [2]])
    }
}
