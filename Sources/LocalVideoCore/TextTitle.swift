// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import CoreText
import Foundation

public enum TitleStyle: String, Codable, CaseIterable, Sendable {
    case simple, statement, caption
    public var name: String { rawValue.capitalized }
    public var symbol: String {
        switch self { case .simple: return "textformat"; case .statement: return "bold"; case .caption: return "rectangle.and.text.magnifyingglass" }
    }
}
public enum TitleColor: String, Codable, CaseIterable, Sendable {
    case white, yellow, black
    public var color: CGColor {
        switch self {
        case .white: return CGColor(gray: 1, alpha: 1)
        case .yellow: return CGColor(red: 1, green: 0.86, blue: 0.2, alpha: 1)
        case .black: return CGColor(gray: 0.03, alpha: 1)
        }
    }
}
public enum TitleAlignment: String, Codable, CaseIterable, Sendable { case left, center, right }

/// Editable project content, with no external font or generated image dependency.
public struct TextTitle: Codable, Equatable, Hashable, Sendable {
    public var text = "Your title"
    public var style: TitleStyle = .simple
    /// Font size as a fraction of canvas height, independent of export resolution.
    public var size: Double = 0.09
    public var color: TitleColor = .white
    public var alignment: TitleAlignment = .center
    public init(style: TitleStyle = .simple) {
        self.style = style; size = style == .statement ? 0.14 : (style == .caption ? 0.065 : 0.09)
    }
    public func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 1000, text.components(separatedBy: .newlines).count <= 8,
              size.isFinite, (0.025...0.25).contains(size),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else {
            throw EditorError("Use a title with 1–1000 characters, up to eight lines, and a size between 2.5% and 25%.")
        }
    }

    /// Core Text supplies the same transparent raster to live playback and FFmpeg export.
    public func raster(width: Int, height: Int, preserveAlpha: Bool = true) throws -> CGImage {
        try validate()
        guard (2...16384).contains(width), (2...16384).contains(height),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw EditorError("Cannot draw title.") }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(canvas)
        if !preserveAlpha { context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(canvas) }
        let layout = try layout(width: width, height: height)
        let box = layout.box, measured = layout.measured, available = layout.available, fontSize = layout.fontSize
        if style == .caption {
            let padding = max(2, fontSize * 0.3)
            let plateWidth = min(available.width, measured.width)
            let plateX = alignment == .left ? box.minX : (alignment == .right ? box.maxX - plateWidth : (Double(width) - plateWidth) / 2)
            let plate = CGRect(x: plateX,
                               y: box.minY, width: min(available.width, measured.width), height: box.height).insetBy(dx: -padding, dy: -padding)
            context.setFillColor(CGColor(gray: color == .black ? 1 : 0, alpha: 0.85))
            context.addPath(CGPath(roundedRect: plate, cornerWidth: padding, cornerHeight: padding, transform: nil)); context.fillPath()
        }
        context.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(layout.setter, CFRange(location: 0, length: 0), CGPath(rect: box, transform: nil), nil)
        CTFrameDraw(frame, context)
        guard let result = context.makeImage() else { throw EditorError("Cannot prepare title.") }
        return result
    }
    /// Viewer handles surround the title rather than the entire transparent canvas.
    public func contentBounds(width: Int, height: Int) throws -> CGRect {
        let value = try layout(width: width, height: height)
        let w = min(value.available.width, value.measured.width)
        let x = alignment == .left ? value.box.minX : (alignment == .right ? value.box.maxX - w : (Double(width) - w) / 2)
        let padding = max(4, value.fontSize * 0.3)
        return CGRect(x: x, y: value.box.minY, width: w, height: value.box.height).insetBy(dx: -padding, dy: -padding)
    }

    private func layout(width: Int, height: Int) throws -> (setter: CTFramesetter, box: CGRect, measured: CGSize, available: CGSize, fontSize: Double) {
        try validate()
        var textAlignment: CTTextAlignment = alignment == .left ? .left : (alignment == .right ? .right : .center)
        let paragraph = withUnsafePointer(to: &textAlignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let available = CGSize(width: Double(width) * 0.82, height: Double(height) * 0.76)
        var fontSize = Double(height) * size
        var setter: CTFramesetter!
        var measured = CGSize.zero
        for _ in 0..<30 {
            let font = CTFontCreateUIFontForLanguage(style == .statement ? .emphasizedSystem : .system, fontSize, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.color,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
            ]
            setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                CGSize(width: available.width, height: .greatestFiniteMagnitude), nil)
            if measured.height <= available.height { break }
            fontSize *= 0.9
        }
        // A small baseline allowance prevents descenders from being clipped.
        let box = CGRect(x: (Double(width) - available.width) / 2, y: (Double(height) - ceil(measured.height) - 2) / 2,
                         width: available.width, height: ceil(measured.height) + 2)
        return (setter, box, measured, available, fontSize)
    }

}

extension VideoProject {
    @discardableResult public mutating func addTitle(_ title: TextTitle, at frame: Int64) throws -> UUID {
        try title.validate()
        guard (0...30_000_000).contains(frame) else { throw EditorError("Choose a valid title position.") }
        var next = self; next.materializePositions()
        let length: Int64 = 150
        let highest = next.clips.filter { next.position(of: $0) < frame + length && next.position(of: $0) + $0.frames > frame }.map(\.lane).max() ?? -1
        let lane = highest + 1
        guard lane < 32 else { throw EditorError("Make room above the visual layers to add a title.") }
        next.visualTrackCount = max(next.visualTrackCount, lane + 1)
        var media = MediaAsset(path: "", duration: 5, width: width, height: height, isImage: true)
        media.title = title
        let clip = Clip(assetID: media.id, inFrame: 0, outFrame: length, startFrame: frame, lane: lane)
        next.assets.append(media); next.clips.append(clip)
        try next.validate(); self = next
        return clip.id
    }

    public mutating func updateTitle(_ id: UUID, to title: TextTitle) throws {
        try title.validate()
        guard let index = clips.firstIndex(where: { $0.id == id }),
              let source = assets.firstIndex(where: { $0.id == clips[index].assetID }), assets[source].isTitle else { throw EditorError("Select a title first.") }
        guard assets[source].title != title else { return }
        var next = self
        // Splits and duplicates keep their appearance but can be edited independently.
        if clips.filter({ $0.assetID == clips[index].assetID }).count > 1 {
            var copy = assets[source]; copy.id = UUID(); copy.title = title
            next.assets.append(copy); next.clips[index].assetID = copy.id
        } else { next.assets[source].title = title }
        try next.validate(); self = next
    }
}
