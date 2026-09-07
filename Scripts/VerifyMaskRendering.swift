// Compile alongside CardProcessor.swift and Processing/*.swift; no API request is made.
import Foundation
import CoreImage
import ImageIO

@main struct VerifyMaskRendering {
    static func main() async throws {
        let processor = CardProcessor()
        let width = 200, height = 220
        let space = CGColorSpaceCreateDeviceRGB()
        for alphaMask in [false, true] {
            var sourcePixels = [UInt8](repeating: 255, count: width * height * 4)
            var maskPixels = sourcePixels
            for y in 0..<height {
                for x in 0..<width {
                    let nx = max(57, min(x, 143)), ny = max(32, min(y, 162))
                    let inside = hypot(Double(x - nx), Double(y - ny)) <= 12
                    let i = (y * width + x) * 4
                    sourcePixels[i] = inside ? 255 : 0
                    sourcePixels[i + 1] = 0
                    sourcePixels[i + 2] = inside ? 0 : 255
                    if (60..<80).contains(x) && (40..<60).contains(y) {
                        sourcePixels[i] = 0; sourcePixels[i + 1] = 255
                    }
                    for c in 0..<3 { maskPixels[i + c] = inside ? 255 : 0 }
                    maskPixels[i + 3] = alphaMask ? (inside ? 255 : 0) : 255
                }
            }
            func image(_ bytes: [UInt8]) -> CGImage {
                CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            }
            let maskData = NSMutableData()
            let destination = CGImageDestinationCreateWithData(maskData, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image(maskPixels), nil)
            precondition(CGImageDestinationFinalize(destination))
            let original = image(sourcePixels)
            let result = try await processor.finish(original: original, image: CIImage(cgImage: original), maskData: maskData as Data)
            let decoded = CGImageSourceCreateWithData(result.pngData as CFData, nil)!
            let png = CGImageSourceCreateImageAtIndex(decoded, 0, nil)!
            let w = png.width, h = png.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            CIContext().render(CIImage(cgImage: png), toBitmap: &bytes, rowBytes: w * 4,
                    bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: space)
            let cornerAlpha = [3, (w - 1) * 4 + 3, ((h - 1) * w) * 4 + 3, (h * w - 1) * 4 + 3].map { bytes[$0] }
            precondition(cornerAlpha.allSatisfy { $0 < 10 }, "Rounded corner background must be transparent")
            let center = ((h / 2) * w + w / 2) * 4
            precondition(bytes[center + 3] > 250 && bytes[center] > 250, "Card content must remain opaque and red: \(Array(bytes[center..<(center + 4)]))")
            precondition(abs(Double(h) / Double(w) - 1.4) < 0.02, "Card aspect ratio must be preserved")
            let custom = try await processor.render(result, aspectRatio: 0.6)
            precondition(abs(Double(custom.corrected.width) / Double(custom.corrected.height) - 0.6) < 0.01,
                         "Custom proportions must control output dimensions")
            let rotated = try await processor.render(result, aspectRatio: 1 / result.aspectRatio, quarterTurns: 1)
            precondition(rotated.corrected.width == result.corrected.height && rotated.corrected.height == result.corrected.width,
                         "Rotation must swap dimensions without stretching the card")
            func greenCenter(_ image: CGImage) -> CGPoint {
                var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                CIContext().render(CIImage(cgImage: image), toBitmap: &pixels, rowBytes: image.width * 4,
                                   bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA8, colorSpace: space)
                var x = 0.0, y = 0.0, count = 0.0
                for index in 0..<(image.width * image.height) where pixels[index * 4 + 1] > 200 && pixels[index * 4] < 50 {
                    x += Double(index % image.width); y += Double(index / image.width); count += 1
                }
                precondition(count > 0, "Orientation marker must survive export")
                return CGPoint(x: x / count, y: y / count)
            }
            let before = greenCenter(result.corrected), after = greenCenter(rotated.corrected)
            precondition(abs(after.x - (Double(result.corrected.height - 1) - before.y)) < 2 && abs(after.y - before.x) < 2,
                         "Rotate must turn pixels clockwise, not just swap dimensions")
            let restored = try await processor.render(result, aspectRatio: result.aspectRatio, quarterTurns: 4)
            precondition(restored.corrected.width == result.corrected.width && restored.corrected.height == result.corrected.height,
                         "Four turns must restore original dimensions")
            print("PASS: \(alphaMask ? "alpha" : "grayscale") mask, transparent PNG corners, opaque card, correct ratio (\(w)x\(h))")
        }
    }
}
