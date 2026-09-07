import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO


struct CardResult: Sendable {
    let original: CGImage
    let corrected: CGImage
    let detection: CardDetection
    let pngData: Data
    let cutout: CIImage
    let automaticRatio: AspectRatioEstimate?
    let aspectRatio: Double
    let quarterTurns: Int
}

// Serial actor keeps image decoding, mask traversal, and rendering off the UI actor.
actor CardProcessor {
    private let context = CIContext()

    private let photoroom = PhotoroomClient()

    func process(_ data: Data, apiKey: String, calibration: CameraCalibration? = nil) async throws -> CardResult {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let original = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3000
              ] as CFDictionary) else { throw CardError.invalidImage }
        let image = CIImage(cgImage: original)
        let upload = try encode(original, type: "public.jpeg", properties: [kCGImageDestinationLossyCompressionQuality: 0.98])
        let maskData = try await photoroom.segmentationMask(image: upload, apiKey: apiKey)
        try Task.checkCancellation()
        return try finish(original: original, image: image, maskData: maskData, calibration: calibration)
    }

    // Kept separate from the HTTP request so mask alignment and transparency can be regression-tested.
    func finish(original: CGImage, image: CIImage, maskData: Data, calibration: CameraCalibration? = nil) throws -> CardResult {
        guard let maskSource = CGImageSourceCreateWithData(maskData as CFData, nil),
              let maskCG = CGImageSourceCreateImageAtIndex(maskSource, 0, nil) else { throw PhotoroomError.invalidResponse }
        let fullMask = CIImage(cgImage: maskCG)
        let scale = min(1, 1600 / max(fullMask.extent.width, fullMask.extent.height))
        let w = max(1, Int((fullMask.extent.width * scale).rounded()))
        let h = max(1, Int((fullMask.extent.height * scale).rounded()))
        let analysisMask = fullMask.transformed(by: CGAffineTransform(scaleX: Double(w) / fullMask.extent.width, y: Double(h) / fullMask.extent.height))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        context.render(analysisMask, toBitmap: &rgba, rowBytes: w * 4,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        // Like the demo, accept either variable alpha or an opaque grayscale mask.
        let alpha = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
        let usesAlpha = Int(alpha.max() ?? 0) - Int(alpha.min() ?? 0) > 30
        let binary: [UInt8] = (0..<(w * h)).map { i in
            if usesAlpha { return alpha[i] > 80 ? 1 : 0 }
            let j = i * 4
            let luminance = Double(rgba[j]) * 0.2126 + Double(rgba[j + 1]) * 0.7152 + Double(rgba[j + 2]) * 0.0722
            return luminance > 30 ? 1 : 0
        }
        let detection = try CardGeometry.detect(mask: binary, width: w, height: h,
                                                sourceWidth: original.width, sourceHeight: original.height)
        let compositingMask = fullMask.transformed(by: CGAffineTransform(
            scaleX: image.extent.width / fullMask.extent.width,
            y: image.extent.height / fullMask.extent.height))
        // Alpha masks must use their alpha channel directly, not their RGB values.
        let cutout = image.applyingFilter(usesAlpha ? "CIBlendWithAlphaMask" : "CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent),
            kCIInputMaskImageKey: compositingMask
        ]).cropped(to: image.extent)
        try Task.checkCancellation()
        // Warp the color and its alpha together, retaining soft/rounded corners.
        let estimate = calibration.flatMap {
            AspectRatioEstimator.estimate(corners: detection.corners, calibration: $0,
                                          imageWidth: Double(original.width), imageHeight: Double(original.height))
        }
        let p = detection.corners
        // Without calibration this is only a provisional preview, never an automatic estimate.
        let previewRatio = max(p[0].distance(to: p[1]), p[2].distance(to: p[3])) /
                           max(p[0].distance(to: p[3]), p[1].distance(to: p[2]))
        let ratio = estimate?.widthOverHeight ?? previewRatio
        let corrected = try rectify(cutout, detection: detection, aspectRatio: ratio)
        let png = try encode(corrected, type: "public.png")
        return CardResult(original: original, corrected: corrected, detection: detection, pngData: png,
                          cutout: cutout, automaticRatio: estimate, aspectRatio: ratio, quarterTurns: 0)
    }

    /// Proportion changes reuse the mask and pixels; they never incur another API request.
    func render(_ result: CardResult, aspectRatio: Double, quarterTurns: Int = 0) throws -> CardResult {
        let turns = (quarterTurns % 4 + 4) % 4
        let sourceRatio = turns % 2 == 0 ? aspectRatio : 1 / aspectRatio
        let rectified = try rectify(result.cutout, detection: result.detection, aspectRatio: sourceRatio)
        let orientation: CGImagePropertyOrientation = [.up, .right, .down, .left][turns]
        let rotated = CIImage(cgImage: rectified).oriented(orientation)
        guard let corrected = context.createCGImage(rotated, from: rotated.extent) else { throw CardError.exportFailed }
        let png = try encode(corrected, type: "public.png")
        return CardResult(original: result.original, corrected: corrected, detection: result.detection, pngData: png,
                          cutout: result.cutout, automaticRatio: result.automaticRatio, aspectRatio: aspectRatio, quarterTurns: turns)
    }

    private func encode(_ image: CGImage, type: String, properties: [CFString: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw CardError.exportFailed }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CardError.exportFailed }
        return data as Data
    }

    private func rectify(_ image: CIImage, detection: CardDetection, aspectRatio: Double) throws -> CGImage {
        let p = detection.corners
        guard aspectRatio.isFinite, (0.2...5).contains(aspectRatio) else { throw CardError.exportFailed }
        guard CardGeometry.valid(p), p.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.x <= image.extent.width && $0.y <= image.extent.height }) else { throw CardError.noCard }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        func ciPoint(_ p: CardPoint) -> CGPoint { CGPoint(x: p.x, y: image.extent.height - p.y) }
        filter.topLeft = ciPoint(p[0]); filter.topRight = ciPoint(p[1])
        filter.bottomRight = ciPoint(p[2]); filter.bottomLeft = ciPoint(p[3])
        guard let rectified = filter.outputImage else { throw CardError.exportFailed }
        // Preserve measured area, but let calibration or the user supply W/H.
        let measuredWidth = max(p[0].distance(to: p[1]), p[2].distance(to: p[3]))
        let measuredHeight = max(p[0].distance(to: p[3]), p[1].distance(to: p[2]))
        let width = sqrt(measuredWidth * measuredHeight * aspectRatio)
        let height = width / aspectRatio
        let fit = min(1, 2400 / max(width, height))
        let size = CGSize(width: width * fit, height: height * fit)
        let normalized = rectified.transformed(by: CGAffineTransform(translationX: -rectified.extent.minX, y: -rectified.extent.minY))
        let output = normalized.transformed(by: CGAffineTransform(scaleX: size.width / normalized.extent.width, y: size.height / normalized.extent.height))
        guard let result = context.createCGImage(output, from: CGRect(origin: .zero, size: size).integral) else { throw CardError.exportFailed }
        return result
    }
}
