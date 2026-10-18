// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVFoundation
import ImageIO

/// Preview proxies stay alive with the player item and disappear when it is released.
final class PreviewResources {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PLSTK-stills-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

extension MediaProbe {
    static func stillImage(_ url: URL) throws -> MediaAsset? {
        // Deliberately bounded to single-frame formats supported by both render paths.
        guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw EditorError("Choose a valid, single-frame PNG or JPEG image.") }
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])?[kCGImagePropertyOrientation as String] as? Int ?? 1
        // Both preview and export use an orientation-normalized image below.
        let swap = (5...8).contains(orientation)
        return MediaAsset(path: url.standardizedFileURL.path, duration: 5,
                          width: swap ? image.height : image.width, height: swap ? image.width : image.height, isImage: true)
    }
}

enum StillImage {
    static func decoded(_ url: URL, maxSize: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize
              ] as CFDictionary) else { throw EditorError("Cannot decode image: \(url.lastPathComponent)") }
        return image
    }
    static func raster(_ media: MediaAsset, width: Int, height: Int, preserveAlpha: Bool = false) throws -> CGImage {
        if let title = media.title { return try title.raster(width: width, height: height, preserveAlpha: preserveAlpha) }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw EditorError("Cannot draw image.") }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        if !preserveAlpha {
            context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let image = try decoded(URL(fileURLWithPath: media.path), maxSize: max(width, height))
        let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let w = max(2, floor(Double(image.width) * scale / 2) * 2)
        let h = max(2, floor(Double(image.height) * scale / 2) * 2)
        context.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
        guard let result = context.makeImage() else { throw EditorError("Cannot prepare image.") }
        return result
    }
    static func normalized(_ media: MediaAsset, width: Int, height: Int, directory: URL, preserveAlpha: Bool = false) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw EditorError("Cannot prepare export image.") }
        CGImageDestinationAddImage(destination, try raster(media, width: width, height: height, preserveAlpha: preserveAlpha), nil)
        guard CGImageDestinationFinalize(destination) else { throw EditorError("Cannot save export image.") }
        return url
    }
    static func movie(_ media: MediaAsset, frames: Int64, width: Int, height: Int, directory: URL, preserveAlpha: Bool = false, opacity: Double = 1) async throws -> URL {
        let output = directory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: (preserveAlpha ? AVVideoCodecType.proRes4444 : AVVideoCodecType.h264),
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? EditorError("Cannot prepare image preview.") }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
                                  [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw EditorError("Cannot allocate image preview.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw EditorError("Cannot draw image preview.") }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setAlpha(preserveAlpha ? opacity : 1)
        context.draw(try raster(media, width: width, height: height, preserveAlpha: preserveAlpha), in: CGRect(x: 0, y: 0, width: width, height: height))
        for frame in frames == 1 ? [Int64(0)] : [0, frames - 1] {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw writer.error ?? EditorError("Image preview encoding failed.") }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            try Task.checkCancellation()
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: frame, timescale: 30)) else {
                throw writer.error ?? EditorError("Image preview encoding failed.")
            }
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: frames, timescale: 30))
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? EditorError("Image preview encoding failed.") }
        return output
    }
}
