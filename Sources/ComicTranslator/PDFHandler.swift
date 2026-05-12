import Foundation
import CoreGraphics
import AppKit
import PDFKit
import UniformTypeIdentifiers

struct PDFPageInfo: Sendable {
    let relativePath: String
    let pageSize: CGSize
}

enum PDFHandler {
    static func renderPages(
        from pdfURL: URL,
        to directory: URL,
        scale: CGFloat = 2.0,
        concurrency: Int = 1
    ) async throws -> [PDFPageInfo] {
        guard let document = PDFDocument(url: pdfURL) else {
            throw PDFHandlerError.cannotOpenPDF
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw PDFHandlerError.emptyPDF
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let semaphore = AsyncSemaphore(value: max(1, min(concurrency, pageCount)))
        var indexedPages: [(Int, PDFPageInfo)] = []
        indexedPages.reserveCapacity(pageCount)

        try await withThrowingTaskGroup(of: (Int, PDFPageInfo).self) { group in
            for index in 0..<pageCount {
                group.addTask { [pdfURL, directory, scale, semaphore] in
                    await semaphore.wait()
                    do {
                        let pageInfo = try renderPage(index: index, from: pdfURL, to: directory, scale: scale)
                        await semaphore.signal()
                        return (index, pageInfo)
                    } catch {
                        await semaphore.signal()
                        throw error
                    }
                }
            }

            for try await page in group {
                indexedPages.append(page)
            }
        }

        let pages = indexedPages
            .sorted { $0.0 < $1.0 }
            .map(\.1)

        guard pages.count == pageCount else {
            throw PDFHandlerError.emptyPDF
        }
        return pages
    }

    private static func renderPage(index: Int, from pdfURL: URL, to directory: URL, scale: CGFloat) throws -> PDFPageInfo {
        guard let document = PDFDocument(url: pdfURL),
              let page = document.page(at: index) else {
            throw PDFHandlerError.cannotRenderPage(index + 1)
        }

        let bounds = page.bounds(for: .mediaBox)
        let pageSize = bounds.size
        let pixelWidth = max(1, Int((pageSize.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((pageSize.height * scale).rounded(.up)))

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PDFHandlerError.cannotRenderPage(index + 1)
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw PDFHandlerError.cannotRenderPage(index + 1)
        }

        let fileName = String(format: "page-%04d.png", index + 1)
        let outputURL = directory.appendingPathComponent(fileName)
        try ImageRenderer.saveImage(image, to: outputURL, format: .png)
        return PDFPageInfo(relativePath: fileName, pageSize: pageSize)
    }

    static func createPDF(from pages: [PDFPageInfo], imageDirectory: URL, to outputURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let consumer = CGDataConsumer(url: outputURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw PDFHandlerError.cannotCreatePDF
        }

        for page in pages {
            let imageURL = imageDirectory.appendingPathComponent(page.relativePath)
            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw PDFHandlerError.cannotReadRenderedPage(page.relativePath)
            }

            var mediaBox = CGRect(origin: .zero, size: page.pageSize)
            context.beginPage(mediaBox: &mediaBox)
            context.draw(image, in: mediaBox)
            context.endPage()
        }

        context.closePDF()
    }
}

enum PDFHandlerError: Error, LocalizedError {
    case cannotOpenPDF
    case emptyPDF
    case cannotRenderPage(Int)
    case cannotCreatePDF
    case cannotReadRenderedPage(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpenPDF: return "无法打开 PDF 文件"
        case .emptyPDF: return "PDF 中没有可处理的页面"
        case .cannotRenderPage(let page): return "无法渲染 PDF 第 \(page) 页"
        case .cannotCreatePDF: return "无法创建输出 PDF"
        case .cannotReadRenderedPage(let file): return "无法读取已渲染页面: \(file)"
        }
    }
}
