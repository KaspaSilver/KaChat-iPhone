import ImageIO
import UIKit

struct PreparedChatImage {
    let data: Data
    let fileName: String
    let mimeType: String
}

/// Prepares a picked photo for sending as a chat message, matching Android's
/// `ImagePrep.prepareForChatMessage` byte budget/dimension approach so a photo sent from either
/// platform lands at a similar on-chain payload size.
enum ImagePrep {
    enum PrepError: Error {
        case invalidImage
        case compressionFailed
    }

    /// Longest edge cap in pixels before compression (small images: group and contact photos).
    static let chatMaxDimension: CGFloat = 1280
    /// The default budget of `prepareForChatMessage` (small images only; chat photos go by
    /// `PhotoTier`).
    static let defaultChatTargetBytes = 20_000
    private static let maxShrinkAttempts = 4
    private static let shrinkFactor: CGFloat = 0.7

    /// Normalizes to a standard-range bitmap, downsamples, and JPEG-compresses, binary-searching
    /// quality to fit `targetBytes` and shrinking dimensions further if quality reduction alone
    /// isn't enough.
    ///
    /// AVIF was tried here previously (matching Android's approach for smaller on-chain payloads)
    /// but was removed: while iOS's own AVIF encode/decode is reliable (guaranteed by ImageIO
    /// since iOS 16), AVIF *decode* support on Android is inconsistent across devices/OS builds -
    /// an iPhone-sent AVIF photo could permanently fail to render for an Android recipient with no
    /// way to detect or recover from that in advance. JPEG decodes everywhere, on every device on
    /// both platforms, so it's the only format guaranteed to actually reach the other person.
    static func prepareForChatMessage(
        _ image: UIImage,
        targetBytes: Int = defaultChatTargetBytes
    ) throws -> PreparedChatImage {
        let data = try prepareJPEGForChatMessage(image, targetBytes: targetBytes)
        return PreparedChatImage(data: data, fileName: "photo.jpg", mimeType: "image/jpeg")
    }

    static func prepareJPEGForChatMessage(
        _ image: UIImage,
        targetBytes: Int = defaultChatTargetBytes
    ) throws -> Data {
        try prepareEncodedDataForChatMessage(image, targetBytes: targetBytes, encoder: jpegData)
    }

    private static func prepareEncodedDataForChatMessage(
        _ image: UIImage,
        targetBytes: Int,
        encoder: (UIImage, CGFloat) -> Data?
    ) throws -> Data {
        var currentImage = try normalizedAndDownscaled(image, maxDimension: chatMaxDimension)

        for _ in 0..<maxShrinkAttempts {
            if let data = compressToQualityBudget(
                currentImage,
                targetBytes: targetBytes,
                encoder: encoder
            ) {
                return data
            }
            let newSize = CGSize(
                width: currentImage.size.width * shrinkFactor,
                height: currentImage.size.height * shrinkFactor
            )
            currentImage = resize(currentImage, to: newSize)
        }

        // Last resort: send whatever the lowest quality produces even if still over budget,
        // rather than rejecting the photo outright.
        guard let data = encoder(currentImage, 0.05) else {
            throw PrepError.compressionFailed
        }
        return data
    }

    // MARK: - Quality tiers (on-chain chat photos)

    /// Long edges tried for a tier, largest first: a big budget buys a big image at a decent
    /// quality, not a small one at quality 1.
    static let tierEdges: [CGFloat] = [3000, 2560, 2240, 2048, 1920, 1600, 1440, 1280, 1080, 960, 800, 640, 480, 360]
    /// The JPEG quality range searched at each edge.
    static let tierMaxQuality: CGFloat = 0.85
    static let tierMinQuality: CGFloat = 0.5

    /// The best-looking JPEG within each of `budgets` bytes, by budget: the LARGEST long edge
    /// (never upscaled) at which quality `tierMinQuality` fits, then the highest quality up to
    /// `tierMaxQuality` that still fits there. Only when nothing fits at `tierMinQuality` even at
    /// the smallest edge does the quality go lower. The image is re-rendered into a fresh
    /// standard-range bitmap, so orientation is applied and nothing of the original's metadata
    /// (EXIF, GPS, camera) is carried, as before. Heavy: call it off the main thread.
    ///
    /// Renders are reused across budgets one at a time, and the quality-0.5 size measured at one
    /// edge predicts the others (size ~ edge squared), so a small budget skips the big edges.
    static func prepareJPEGForTiers(_ image: UIImage, budgets: [Int]) throws -> [Int: Data] {
        guard image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0 else {
            throw PrepError.invalidImage
        }
        let originalEdge = max(image.size.width, image.size.height)
        var edges = tierEdges.filter { $0 < originalEdge }
        edges.insert(min(originalEdge, tierEdges[0]), at: 0)

        var renderedEdge: CGFloat?
        var rendered: UIImage?
        func render(_ edge: CGFloat) -> UIImage {
            if renderedEdge == edge, let rendered { return rendered }
            let scale = edge / originalEdge
            let scaled = resize(image, to: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            renderedEdge = edge
            rendered = scaled
            return scaled
        }
        var minQualitySize: [CGFloat: Int] = [:]
        func sizeAtMinQuality(_ edge: CGFloat) -> (Int, Data)? {
            guard let data = jpegData(from: render(edge), quality: tierMinQuality) else { return nil }
            minQualitySize[edge] = data.count
            return (data.count, data)
        }
        func predicted(_ edge: CGFloat) -> Int? {
            guard let (known, size) = minQualitySize.max(by: { $0.key < $1.key }) else { return nil }
            return Int(Double(size) * Double(edge * edge) / Double(known * known))
        }

        var results: [Int: Data] = [:]
        for budget in budgets.sorted(by: >) {
            var chosen: Data?
            for edge in edges {
                if let known = minQualitySize[edge], known > budget { continue }
                if minQualitySize[edge] == nil, let guess = predicted(edge), guess > budget * 13 / 10 { continue }
                guard let (size, floorData) = sizeAtMinQuality(edge), size <= budget else { continue }
                // Fits at the floor: the best quality that still fits, at this edge.
                var best = floorData
                var low = tierMinQuality
                var high = tierMaxQuality
                for _ in 0..<6 {
                    let mid = (low + high) / 2
                    guard let data = jpegData(from: render(edge), quality: mid) else { break }
                    if data.count <= budget {
                        best = data
                        low = mid
                    } else {
                        high = mid
                    }
                }
                chosen = best
                break
            }
            if chosen == nil, let smallest = edges.last {
                // Nothing fits at the quality floor: the smallest edge, below the floor.
                chosen = compressToQualityBudget(render(smallest), targetBytes: budget, encoder: jpegData)
                    ?? jpegData(from: render(smallest), quality: 0.05)
            }
            guard let chosen else { throw PrepError.compressionFailed }
            results[budget] = chosen
        }
        return results
    }

    /// The tier's photo on a path - one JPEG within its byte budget.
    static func prepareForTier(_ image: UIImage, tier: PhotoTier, forGroup group: Bool) throws -> PreparedChatImage {
        let budget = tier.maxBytes(forGroup: group)
        guard let data = try prepareJPEGForTiers(image, budgets: [budget])[budget] else {
            throw PrepError.compressionFailed
        }
        return PreparedChatImage(data: data, fileName: "photo.jpg", mimeType: "image/jpeg")
    }

    private static func normalizedAndDownscaled(
        _ image: UIImage,
        maxDimension: CGFloat
    ) throws -> UIImage {
        guard image.size.width.isFinite,
              image.size.height.isFinite,
              image.size.width > 0,
              image.size.height > 0 else {
            throw PrepError.invalidImage
        }

        let longestEdge = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / longestEdge)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return resize(image, to: newSize)
    }

    private static func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        guard size.width >= 1, size.height >= 1 else { return image }

        // Photos can arrive as HDR/extended-sRGB images. Passing those directly to
        // `UIImage.jpegData` makes ImageIO perform an accelerated extended-range conversion;
        // on Mac Catalyst that conversion can abort inside QuartzCore while creating a Metal
        // context. Render once into an explicitly standard-range bitmap so every later JPEG
        // attempt works with ordinary 8-bit color data.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        let bounds = CGRect(origin: .zero, size: size)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(bounds)
            image.draw(in: bounds)
        }
    }

    /// Binary-searches encoder quality for the highest quality that still fits `targetBytes`.
    /// Returns nil if even the lowest quality tried doesn't fit - the caller should shrink the
    /// image's dimensions and try again rather than degrade quality further.
    private static func compressToQualityBudget(
        _ image: UIImage,
        targetBytes: Int,
        encoder: (UIImage, CGFloat) -> Data?
    ) -> Data? {
        var low: CGFloat = 0.05
        var high: CGFloat = 0.95

        guard let lowestQualityData = encoder(image, low),
              lowestQualityData.count <= targetBytes else {
            return nil
        }

        var best = lowestQualityData
        for _ in 0..<8 {
            let mid = (low + high) / 2
            guard let data = encoder(image, mid) else { break }
            if data.count <= targetBytes {
                best = data
                low = mid
            } else {
                high = mid
            }
        }
        return best
    }

    private static func jpegData(from image: UIImage, quality: CGFloat) -> Data? {
        guard let cgImage = image.cgImage else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
