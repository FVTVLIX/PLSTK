// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVFoundation
import CoreImage

struct VisualCompositionLayer {
    var clip: Clip
    let position: Int64
    let track: CMPersistentTrackID
    let fitted: CGAffineTransform
    let outgoing: Int64
    func gain(_ frame: Double) -> Double {
        let local = frame - Double(position)
        let entering = clip.dissolveFrames == 0 ? 1 : min(1, max(0, local / Double(clip.dissolveFrames)))
        let leaving = outgoing == 0 ? 1 : min(1, max(0, (Double(clip.frames) - local) / Double(outgoing)))
        return clip.opacity * clip.fadeGain(at: local) * entering * leaving
    }
}

final class VisualCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let requiredSourceTrackIDs: [NSValue]?
    let layers: [VisualCompositionLayer]
    init(range: CMTimeRange, layers: [VisualCompositionLayer]) {
        timeRange = range; self.layers = layers
        requiredSourceTrackIDs = layers.map { NSNumber(value: $0.track) }
    }
    func transforming(_ id: UUID, to value: VisualTransform) -> VisualCompositionInstruction {
        VisualCompositionInstruction(range: timeRange, layers: layers.map { original in
            var changed = original
            if changed.clip.id == id { changed.clip.transform = value }
            return changed
        })
    }
}

/// Sum premultiplied pixels within a dissolving track before compositing tracks.
/// Fading two independent layers over each other would incorrectly darken the blend.
final class VisualVideoCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String: Any]? { [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]] }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    private let queue = DispatchQueue(label: "studio.localvideo.visual-compositor")
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .cacheIntermediates: false])
    private var renderContext: AVVideoCompositionRenderContext?
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { queue.sync { renderContext = newRenderContext } }
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? VisualCompositionInstruction,
                      let buffer = renderContext?.newPixelBuffer() else {
                    request.finish(with: EditorError("Cannot prepare transition preview.")); return
                }
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                let frame = request.compositionTime.seconds * 30
                var result = CIImage(color: .black).cropped(to: bounds)
                for lane in Set(instruction.layers.map { $0.clip.lane }).sorted() {
                    var combined = CIImage(color: .clear).cropped(to: bounds)
                    for layer in instruction.layers where layer.clip.lane == lane {
                        guard let source = request.sourceFrame(byTrackID: layer.track) else {
                            request.finish(with: EditorError("A transition preview frame is unavailable.")); return
                        }
                        let matrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(CVPixelBufferGetHeight(source)))
                            .concatenating(layer.fitted)
                            .concatenating(layer.clip.transform.canvasTransform(width: width, height: height))
                            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height)))
                        let gain = layer.gain(frame)
                        let image = CIImage(cvPixelBuffer: source).transformed(by: matrix).cropped(to: bounds)
                            .applyingFilter("CIColorMatrix", parameters: [
                                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: gain)])
                        combined = image.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: combined])
                    }
                    result = combined.composited(over: result)
                }
                context.render(result, to: buffer, bounds: bounds, colorSpace: colorSpace)
                request.finish(withComposedVideoFrame: buffer)
            }
        }
    }
    func cancelAllPendingVideoCompositionRequests() { queue.sync {} }
}
