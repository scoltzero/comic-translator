import Foundation

// MARK: - 自适应批次规划器
//
// 将 0..<pageCount 的连续页索引，按“并发 W”和“每批页数上限 B”划分为若干连续批次：
//   - 批次数量 = max(min(W, N), ceil(N/B))；N=0 时返回空
//   - 尽量均匀分配
//   - 每批页数不超过 B
//   - 保持原始顺序，各批连续、互不重叠、覆盖全部页（0..<N 无重复、无遗漏）
//
// 纯函数、无副作用，可独立测试，供 Translator.swift 复用。

enum BatchPlanner {

    /// 计算批次数量。
    /// - Returns: `max(min(W, N), ceil(N/B))`；`N <= 0` 时返回 0。
    static func batchCount(pageCount: Int, concurrency: Int, maxPagesPerBatch: Int = 8) -> Int {
        let n = pageCount
        guard n > 0 else { return 0 }

        let w = max(1, concurrency)
        let b = max(1, maxPagesPerBatch)

        let byConcurrency = min(w, n)
        let byCap = (n + b - 1) / b // ceil(n / b)
        return max(byConcurrency, byCap)
    }

    /// 规划连续批次。
    /// - Returns: 按 0..<pageCount 顺序排列的连续批次；页数为 0 时返回空数组。
    ///
    /// 每批用 `Range<Int>` 表示（左闭右开），因此天然连续、不重叠。
    static func planBatches(
        pageCount: Int,
        concurrency: Int,
        maxPagesPerBatch: Int = 8
    ) -> [Range<Int>] {
        guard pageCount > 0 else { return [] }

        let k = batchCount(pageCount: pageCount, concurrency: concurrency, maxPagesPerBatch: maxPagesPerBatch)
        let base = pageCount / k
        let remainder = pageCount % k

        var batches: [Range<Int>] = []
        batches.reserveCapacity(k)
        var start = 0
        for index in 0..<k {
            let size = base + (index < remainder ? 1 : 0)
            batches.append(start..<(start + size))
            start += size
        }
        return batches
    }

    /// 展开为页索引数组形式，便于逐页处理。
    /// - Returns: `[[Int]]`，等价于 `planBatches` 的展开视图。
    static func planPageIndices(
        pageCount: Int,
        concurrency: Int,
        maxPagesPerBatch: Int = 8
    ) -> [[Int]] {
        return planBatches(pageCount: pageCount, concurrency: concurrency, maxPagesPerBatch: maxPagesPerBatch)
            .map { Array($0) }
    }
}

// MARK: - 按字符/token 预算进一步拆分（纯函数，保持顺序）
//
// 在批次既定的基础上，依据文本预算把一组的元素再切成更小的子组：
//   - 贪婪累加，逐项放入当前子组，放不下时另起一组
//   - 不改变输入顺序：拼接所有子组 == 原数组
//   - 单个元素权重超过预算时，该元素独占一组（无法再拆分）

extension BatchPlanner {

    /// 通用预算拆分。
    /// - Parameters:
    ///   - items: 有序元素。
    ///   - weight: 计算元素权重的闭包（如按 UTF-8 字符数估算）。
    ///   - budget: 每组权重上限。
    /// - Returns: 保持顺序的子组数组。
    static func splitByBudget<T>(
        _ items: [T],
        weight: (T) -> Int,
        budget: Int
    ) -> [[T]] {
        guard budget > 0 else {
            return items.map { [$0] }
        }

        var groups: [[T]] = []
        var current: [T] = []
        var currentWeight = 0

        for item in items {
            let w = weight(item)
            if current.isEmpty {
                current = [item]
                currentWeight = w
            } else if currentWeight + w <= budget {
                current.append(item)
                currentWeight += w
            } else {
                groups.append(current)
                current = [item]
                currentWeight = w
            }
        }

        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    /// 按 UTF-8 字符数预算拆分字符串数组的便捷接口。
    static func splitTextByUTF8Budget(_ items: [String], budget: Int) -> [[String]] {
        return splitByBudget(items, weight: { $0.utf8.count }, budget: budget)
    }
}
