import Foundation
import CoreGraphics
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - 背景/文字颜色采样

enum BackgroundSampler {
    static func sampleBackgroundColor(image: CGImage, normalizedBox: CGRect) -> (r: Double, g: Double, b: Double) {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)

        let px = (normalizedBox.origin.x * imgW).rounded()
        let py = ((1.0 - normalizedBox.origin.y - normalizedBox.height) * imgH).rounded()
        let pw = (normalizedBox.width * imgW).rounded()
        let ph = (normalizedBox.height * imgH).rounded()

        let margin: CGFloat = 3
        let sampleX = max(0, px - margin)
        let sampleY = max(0, py - margin)
        let sampleW = min(imgW - sampleX, pw + margin * 2)
        let sampleH = min(imgH - sampleY, ph + margin * 2)

        let sampleRect = CGRect(x: sampleX, y: sampleY, width: sampleW, height: sampleH)
        guard sampleRect.width > 1, sampleRect.height > 1,
              let cropped = image.cropping(to: sampleRect) else {
            return (1, 1, 1)
        }

        return sampleEdges(cropped)
    }

    static func isLight(_ r: Double, _ g: Double, _ b: Double) -> Bool {
        (0.299 * r + 0.587 * g + 0.114 * b) > 0.5
    }

    static func sampleTextColor(
        image: CGImage,
        normalizedBoxes: [CGRect],
        background: (r: Double, g: Double, b: Double)
    ) -> (r: Double, g: Double, b: Double) {
        let bgR = Int(background.r * 255)
        let bgG = Int(background.g * 255)
        let bgB = Int(background.b * 255)
        var votes: [Int: (r: Int, g: Int, b: Int, count: Int)] = [:]

        for box in normalizedBoxes {
            collectTextPixelVotes(image: image, normalizedBox: box, bgR: bgR, bgG: bgG, bgB: bgB, into: &votes)
        }

        guard let winner = votes.max(by: { $0.value.count < $1.value.count })?.value,
              winner.count > 0 else {
            return isLight(background.r, background.g, background.b) ? (0, 0, 0) : (1, 1, 1)
        }

        let count = Double(winner.count)
        return (
            Double(winner.r) / count / 255.0,
            Double(winner.g) / count / 255.0,
            Double(winner.b) / count / 255.0
        )
    }

    private static func collectTextPixelVotes(
        image: CGImage,
        normalizedBox: CGRect,
        bgR: Int,
        bgG: Int,
        bgB: Int,
        into votes: inout [Int: (r: Int, g: Int, b: Int, count: Int)]
    ) {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)

        let px = (normalizedBox.origin.x * imgW).rounded()
        let py = ((1.0 - normalizedBox.origin.y - normalizedBox.height) * imgH).rounded()
        let pw = (normalizedBox.width * imgW).rounded()
        let ph = (normalizedBox.height * imgH).rounded()

        let insetX = pw * 0.15
        let insetY = ph * 0.15
        let sampleX = max(0, px + insetX)
        let sampleY = max(0, py + insetY)
        let sampleW = max(1, pw - insetX * 2)
        let sampleH = max(1, ph - insetY * 2)

        let sampleRect = CGRect(x: sampleX, y: sampleY, width: sampleW, height: sampleH)
        guard sampleRect.width > 2, sampleRect.height > 2,
              let cropped = image.cropping(to: sampleRect) else { return }

        let width = cropped.width
        let height = cropped.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))

        let threshold2 = 60 * 60
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                let dr = r - bgR
                let dg = g - bgG
                let db = b - bgB
                guard dr * dr + dg * dg + db * db >= threshold2 else { continue }

                let bucket = hsvBucket(r: r, g: g, b: b)
                var entry = votes[bucket] ?? (0, 0, 0, 0)
                entry.r += r
                entry.g += g
                entry.b += b
                entry.count += 1
                votes[bucket] = entry
            }
        }
    }

    private static func hsvBucket(r: Int, g: Int, b: Int) -> Int {
        let rf = Double(r) / 255.0
        let gf = Double(g) / 255.0
        let bf = Double(b) / 255.0
        let maxC = max(rf, gf, bf)
        let minC = min(rf, gf, bf)
        let delta = maxC - minC
        let saturation = maxC == 0 ? 0 : delta / maxC
        var hue: Double = 0

        if delta > 0 {
            if maxC == rf {
                hue = ((gf - bf) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == gf {
                hue = ((bf - rf) / delta) + 2
            } else {
                hue = ((rf - gf) / delta) + 4
            }
            hue *= 60
            if hue < 0 { hue += 360 }
        }

        let hueBucket = min(11, Int(hue / 30))
        let saturationBucket = min(3, Int(saturation * 4))
        let valueBucket = min(3, Int(maxC * 4))
        return hueBucket * 16 + saturationBucket * 4 + valueBucket
    }

    private static func sampleEdges(_ image: CGImage) -> (r: Double, g: Double, b: Double) {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (1, 1, 1) }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var rs: [UInt8] = []
        var gs: [UInt8] = []
        var bs: [UInt8] = []
        rs.reserveCapacity((width + height) * 4)
        gs.reserveCapacity((width + height) * 4)
        bs.reserveCapacity((width + height) * 4)

        func collect(_ offset: Int) {
            rs.append(pixels[offset])
            gs.append(pixels[offset + 1])
            bs.append(pixels[offset + 2])
        }

        let topRows = [0, min(1, height - 1)]
        let bottomRows = [height - 1, max(0, height - 2)]
        let leftCols = [0, min(1, width - 1)]
        let rightCols = [width - 1, max(0, width - 2)]

        for y in topRows + bottomRows where y >= 0 && y < height {
            for x in 0..<width {
                collect(y * bytesPerRow + x * bytesPerPixel)
            }
        }
        for x in leftCols + rightCols where x >= 0 && x < width {
            for y in 0..<height {
                collect(y * bytesPerRow + x * bytesPerPixel)
            }
        }

        guard !rs.isEmpty else { return (1, 1, 1) }
        rs.sort()
        gs.sort()
        bs.sort()
        return (
            Double(rs[rs.count / 2]) / 255.0,
            Double(gs[gs.count / 2]) / 255.0,
            Double(bs[bs.count / 2]) / 255.0
        )
    }
}

// MARK: - 图片渲染

enum ImageRenderer {
    static func renderTranslated(
        original: CGImage,
        textBlocks: [MergedTextBlock],
        translations: [String]
    ) -> CGImage? {
        let width = original.width
        let height = original.height

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(original, in: fullRect)

        let imageSize = CGSize(width: width, height: height)

        for (index, block) in textBlocks.enumerated() {
            guard index < translations.count, !translations[index].isEmpty else { continue }

            let blockRect = pixelRect(for: block.boundingBox, imageSize: imageSize)
            guard blockRect.width > 1, blockRect.height > 1 else { continue }

            let bg = BackgroundSampler.sampleBackgroundColor(image: original, normalizedBox: block.boundingBox)
            let textColor = BackgroundSampler.sampleTextColor(
                image: original,
                normalizedBoxes: block.lines.map(\.boundingBox),
                background: bg
            )

            context.setFillColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1.0)
            for line in block.lines {
                let lineRect = pixelRect(for: line.boundingBox, imageSize: imageSize)
                    .insetBy(dx: -3, dy: -2)
                context.fill(lineRect)
            }

            let fontSize = fittedFontSize(
                text: translations[index],
                block: block,
                blockRect: blockRect,
                imageSize: imageSize
            )

            drawText(
                translations[index],
                inBlock: blockRect,
                fontSize: fontSize,
                textColor: textColor,
                context: context,
                imgHeight: CGFloat(height),
                isVertical: block.isVertical
            )
        }

        return context.makeImage()
    }

    private static func pixelRect(for normalizedBox: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: normalizedBox.origin.x * imageSize.width,
            y: normalizedBox.origin.y * imageSize.height,
            width: normalizedBox.width * imageSize.width,
            height: normalizedBox.height * imageSize.height
        )
    }

    private static func fittedFontSize(
        text: String,
        block: MergedTextBlock,
        blockRect: CGRect,
        imageSize: CGSize
    ) -> CGFloat {
        let lineHeights = block.lines.map { $0.boundingBox.height * imageSize.height }.sorted()
        let medianLineHeight = lineHeights.isEmpty ? blockRect.height : lineHeights[lineHeights.count / 2]
        var fontSize = max(8, min(96, medianLineHeight * 0.85))

        let fitSize = block.isVertical
            ? CGSize(width: blockRect.height, height: blockRect.width)
            : CGSize(width: blockRect.width, height: blockRect.height)

        for _ in 0..<10 {
            let measured = measure(text: text, width: max(1, fitSize.width), fontSize: fontSize)
            if measured.height <= fitSize.height * 1.08 { break }
            fontSize *= 0.88
        }
        return max(8, fontSize)
    }

    private static func measure(text: String, width: CGFloat, fontSize: CGFloat) -> CGSize {
        let font = NSFont.systemFont(ofSize: fontSize)
        let size = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return size.size
    }

    private static func drawText(
        _ text: String,
        inBlock blockRect: CGRect,
        fontSize: CGFloat,
        textColor: (r: Double, g: Double, b: Double),
        context: CGContext,
        imgHeight: CGFloat,
        isVertical: Bool
    ) {
        if isVertical {
            drawRotatedText(
                text,
                inBlock: blockRect,
                fontSize: fontSize,
                textColor: textColor,
                context: context
            )
            return
        }

        let attrStr = attributedText(text, fontSize: fontSize, textColor: textColor)

        context.saveGState()
        context.translateBy(x: 0, y: imgHeight)
        context.scaleBy(x: 1, y: -1)

        let flippedY = imgHeight - blockRect.origin.y - blockRect.height
        let drawRect = CGRect(x: blockRect.origin.x, y: flippedY, width: blockRect.width, height: blockRect.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        attrStr.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
        NSGraphicsContext.restoreGraphicsState()

        context.restoreGState()
    }

    private static func drawRotatedText(
        _ text: String,
        inBlock blockRect: CGRect,
        fontSize: CGFloat,
        textColor: (r: Double, g: Double, b: Double),
        context: CGContext
    ) {
        let canvasWidth = max(1, Int(blockRect.height.rounded(.up)))
        let canvasHeight = max(1, Int(blockRect.width.rounded(.up)))

        guard let textContext = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: canvasWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        textContext.clear(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        textContext.saveGState()
        textContext.translateBy(x: 0, y: CGFloat(canvasHeight))
        textContext.scaleBy(x: 1, y: -1)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: textContext, flipped: true)
        let attrStr = attributedText(text, fontSize: fontSize, textColor: textColor)
        attrStr.draw(
            with: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            context: nil
        )
        NSGraphicsContext.restoreGraphicsState()
        textContext.restoreGState()

        guard let textImage = textContext.makeImage() else { return }

        context.saveGState()
        context.translateBy(x: blockRect.midX, y: blockRect.midY)
        context.rotate(by: .pi / 2)
        context.draw(
            textImage,
            in: CGRect(
                x: -CGFloat(canvasWidth) / 2,
                y: -CGFloat(canvasHeight) / 2,
                width: CGFloat(canvasWidth),
                height: CGFloat(canvasHeight)
            )
        )
        context.restoreGState()
    }

    private static func attributedText(
        _ text: String,
        fontSize: CGFloat,
        textColor: (r: Double, g: Double, b: Double)
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byWordWrapping

        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor(red: textColor.r, green: textColor.g, blue: textColor.b, alpha: 1.0),
                .paragraphStyle: paragraphStyle
            ]
        )
    }

    static func saveImage(_ image: CGImage, to url: URL, format: UTType) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "ImageRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建输出: \(url.lastPathComponent)"])
        }

        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "ImageRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "保存失败: \(url.lastPathComponent)"])
        }
    }

    static func imageFormat(for url: URL) -> UTType {
        switch url.pathExtension.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "tiff", "tif": return .tiff
        case "bmp": return .bmp
        case "gif": return .gif
        case "heic": return .heic
        default: return .png
        }
    }
}
