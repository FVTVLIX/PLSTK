// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import CoreGraphics
import Foundation

/// Offsets are output pixels from the fitted canvas centre; positive Y is down.
public struct VisualTransform: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var scale: Double
    public var rotation: Double
    public init(x: Double = 0, y: Double = 0, scale: Double = 1, rotation: Double = 0) {
        self.x = x; self.y = y; self.scale = scale; self.rotation = rotation
    }
    public var isValid: Bool {
        [x, y, scale, rotation].allSatisfy(\.isFinite) && abs(x) <= 32768 && abs(y) <= 32768 &&
            (0.05...4).contains(scale) && (-360...360).contains(rotation)
    }
    public func canvasTransform(width: Int, height: Int) -> CGAffineTransform {
        CGAffineTransform(translationX: -Double(width) / 2, y: -Double(height) / 2)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: Double(width) / 2 + x, y: Double(height) / 2 + y))
    }
}
