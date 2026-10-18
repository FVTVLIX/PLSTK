// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import Foundation

/// Scroll speed is measured in points, so the edge remains usable at every zoom.
public enum TimelineNavigation {
    public static func edgeVelocity(pointer: Double, viewport: Double) -> Double {
        guard pointer.isFinite, viewport.isFinite, viewport > 0 else { return 0 }
        let band = min(56, viewport / 3)
        guard pointer >= -band, pointer <= viewport + band else { return 0 }
        if pointer < band { return -600 * pow(min(1, max(0, (band - pointer) / band)), 2) }
        if pointer > viewport - band { return 600 * pow(min(1, max(0, (pointer - viewport + band) / band)), 2) }
        return 0
    }

    public static func scrollOffset(_ offset: Double, velocity: Double, elapsed: Double, maximum: Double) -> Double {
        guard offset.isFinite, velocity.isFinite, elapsed.isFinite, maximum.isFinite else { return 0 }
        return min(max(0, maximum), max(0, offset + velocity * min(0.05, max(0, elapsed))))
    }

    /// Gestures use a stationary viewport; scrolling adds the distance under the pointer.
    public static func dragDistance(translation: Double, initialOffset: Double, currentOffset: Double) -> Double {
        guard translation.isFinite, initialOffset.isFinite, currentOffset.isFinite else { return 0 }
        return translation + currentOffset - initialOffset
    }
}
