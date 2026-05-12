import CoreGraphics
import Foundation

struct TextBlock: Identifiable, Sendable {
    let id: UUID
    let text: String
    let boundingBox: CGRect
    let confidence: Float
    let isVertical: Bool

    init(from result: OCRResult) {
        self.id = UUID()
        self.text = result.text
        self.boundingBox = result.boundingBox
        self.confidence = result.confidence
        self.isVertical = result.boundingBox.width < result.boundingBox.height * 0.5
    }
}

struct MergedTextBlock: Identifiable, Sendable {
    let id: UUID
    let text: String
    let boundingBox: CGRect
    let lines: [TextBlock]
    let isVertical: Bool

    init(lines: [TextBlock]) {
        self.id = UUID()
        self.lines = lines
        self.isVertical = lines.first?.isVertical ?? false
        self.text = lines.map(\.text).joined(separator: isVertical ? "" : " ")
        self.boundingBox = lines.reduce(CGRect.null) { $0.union($1.boundingBox) }
    }
}

struct TextRegion: Sendable {
    let blocks: [TextBlock]
    let boundingBox: CGRect
    let fontSizeCategory: FontSizeCategory

    init(blocks: [TextBlock], fontSizeCategory: FontSizeCategory) {
        self.blocks = blocks
        self.fontSizeCategory = fontSizeCategory
        self.boundingBox = blocks.reduce(CGRect.null) { $0.union($1.boundingBox) }
    }
}

enum FontSizeCategory: Sendable {
    case title
    case body
    case footnote
}

struct RegionSegmenter {
    func segment(blocks: [TextBlock]) -> [TextRegion] {
        guard !blocks.isEmpty else { return [] }

        let withAvgHeight = blocks.map { block in
            (block, block.boundingBox.height)
        }
        let clusters = clusterHeights(withAvgHeight.map(\.1).sorted())

        var blocksByCluster: [FontSizeCategory: [TextBlock]] = [
            .title: [],
            .body: [],
            .footnote: []
        ]
        for (block, avgHeight) in withAvgHeight {
            blocksByCluster[categoryForHeight(avgHeight, clusters: clusters), default: []].append(block)
        }

        var regions: [TextRegion] = []
        for category in [FontSizeCategory.title, .body, .footnote] {
            guard let categoryBlocks = blocksByCluster[category], !categoryBlocks.isEmpty else { continue }
            regions.append(contentsOf: splitByParagraphGaps(categoryBlocks, category: category))
        }
        return regions
    }

    private func clusterHeights(_ heights: [CGFloat]) -> [CGFloat] {
        guard heights.count > 1 else { return heights }
        let minHeight = heights.first!
        let maxHeight = heights.last!
        let range = maxHeight - minHeight

        if range < 0.005 || (minHeight > 0 && range / minHeight < 0.5) {
            return [heights.reduce(0, +) / CGFloat(heights.count)]
        }

        let split = findBestSplit(heights)
        let left = Array(heights[..<split])
        let right = Array(heights[split...])
        let leftMean = left.reduce(0, +) / CGFloat(left.count)
        let rightMean = right.reduce(0, +) / CGFloat(right.count)

        if rightMean / leftMean > 1.8 {
            let larger = left.count >= right.count ? left : right
            if larger.count > 2 {
                let subSplit = findBestSplit(larger)
                let subLeft = larger[..<subSplit]
                let subRight = larger[subSplit...]
                let subLeftMean = subLeft.reduce(0, +) / CGFloat(subLeft.count)
                let subRightMean = subRight.reduce(0, +) / CGFloat(subRight.count)
                if subRightMean / subLeftMean > 1.5 {
                    return [subLeft.first!, subLeft.last!, subRight.last!, right.last!].sorted()
                }
            }
            return [leftMean, rightMean]
        }
        return [heights.reduce(0, +) / CGFloat(heights.count)]
    }

    private func findBestSplit(_ sorted: [CGFloat]) -> Int {
        var bestGap: CGFloat = 0
        var bestIndex = 1
        for index in 1..<sorted.count {
            let gap = sorted[index] - sorted[index - 1]
            if gap > bestGap {
                bestGap = gap
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func categoryForHeight(_ height: CGFloat, clusters: [CGFloat]) -> FontSizeCategory {
        let sorted = clusters.sorted()
        switch sorted.count {
        case 1:
            return .body
        case 2:
            return height > (sorted[0] + sorted[1]) / 2 ? .title : .body
        default:
            let mid1 = (sorted[0] + sorted[1]) / 2
            let mid2 = (sorted[1] + sorted[2]) / 2
            if height > mid2 { return .title }
            if height > mid1 { return .body }
            return .footnote
        }
    }

    private func splitByParagraphGaps(_ blocks: [TextBlock], category: FontSizeCategory) -> [TextRegion] {
        let sorted = blocks.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        guard sorted.count > 1 else {
            return [TextRegion(blocks: sorted, fontSizeCategory: category)]
        }

        var gaps: [CGFloat] = []
        for index in 1..<sorted.count {
            let previousBottom = sorted[index - 1].boundingBox.minY
            let currentTop = sorted[index].boundingBox.maxY
            gaps.append(previousBottom - currentTop)
        }
        let medianGap = gaps.sorted()[gaps.count / 2]
        let splitThreshold = max(medianGap * 2.0, 0.01)

        var groups: [[TextBlock]] = []
        var current = [sorted[0]]
        for index in 1..<sorted.count {
            let previous = sorted[index - 1]
            let next = sorted[index]
            if gaps[index - 1] > splitThreshold || shouldSplitLayout(previous: previous, next: next) {
                groups.append(current)
                current = [next]
            } else {
                current.append(next)
            }
        }
        groups.append(current)

        return groups.map { TextRegion(blocks: $0, fontSizeCategory: category) }
    }

    private func shouldSplitLayout(previous: TextBlock, next: TextBlock) -> Bool {
        let verticalOverlap = min(previous.boundingBox.maxY, next.boundingBox.maxY)
            - max(previous.boundingBox.minY, next.boundingBox.minY)
        let minHeight = min(previous.boundingBox.height, next.boundingBox.height)
        let sameVisualRow = minHeight > 0 && verticalOverlap > minHeight * 0.45

        if sameVisualRow {
            let horizontalGap = max(
                max(previous.boundingBox.minX, next.boundingBox.minX) - min(previous.boundingBox.maxX, next.boundingBox.maxX),
                0
            )
            return horizontalGap > minHeight * 2.0
        }

        return !hasHorizontalOverlap(previous.boundingBox, next.boundingBox)
    }

    private func hasHorizontalOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        guard overlap > 0 else { return false }
        return overlap > min(a.width, b.width) * 0.2
    }
}

struct TextMerger {
    var lineSpacingThreshold: CGFloat = 1.5

    func merge(blocks: [TextBlock]) -> [MergedTextBlock] {
        guard !blocks.isEmpty else { return [] }

        let sorted = blocks.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        var groups: [[TextBlock]] = []
        var current = [sorted[0]]

        for index in 1..<sorted.count {
            let previous = sorted[index - 1]
            let next = sorted[index]
            let gap = previous.boundingBox.minY - next.boundingBox.maxY
            let threshold = previous.boundingBox.height * lineSpacingThreshold

            if gap < threshold && hasHorizontalOverlap(previous.boundingBox, next.boundingBox) {
                current.append(next)
            } else {
                groups.append(current)
                current = [next]
            }
        }
        groups.append(current)

        return groups.map { MergedTextBlock(lines: $0) }
    }

    private func hasHorizontalOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        guard overlap > 0 else { return false }
        return overlap > min(a.width, b.width) * 0.3
    }
}
