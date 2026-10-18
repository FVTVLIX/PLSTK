// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import LocalVideoCore
import SwiftUI

/// Handles use the fitted output canvas, matching the numeric centre-pivot transform.
struct CanvasTransformView: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    @State private var origin: VisualTransform?
    @State private var cancelled = false

    var body: some View {
        GeometryReader { geometry in
            overlay(size: geometry.size)
        }
        .onChange(of: store.canvasDraft) { _, draft in
            if draft == nil, origin != nil { cancelled = true }
        }
        .onExitCommand { cancelled = true; store.cancelCanvasTransform() }
        .onDisappear { store.cancelCanvasTransform() }
    }
    private func overlay(size: CGSize) -> some View {
            let value = store.canvasDraft ?? clip.transform
            let points = corners(value, size: size)
            let centre = CGPoint(x: size.width / 2 + value.x * size.width / Double(store.project.width),
                                 y: size.height / 2 + value.y * size.height / Double(store.project.height))
            let top = CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
            let angle = value.rotation * .pi / 180
            // Keep the rotation handle inside an identity/full-canvas selection.
            let rotate = CGPoint(x: top.x - sin(angle) * 24, y: top.y + cos(angle) * 24)
            return ZStack {
                Path { path in
                    path.addLines(points); path.closeSubpath()
                }.fill(.white.opacity(0.001)).contentShape(Path { path in path.addLines(points); path.closeSubpath() })
                    .gesture(drag(.move, size: size))
                    .accessibilityLabel("Move selected visual")
                Path { path in path.addLines(points); path.closeSubpath() }
                    .stroke(.white, style: StrokeStyle(lineWidth: 1, dash: [5, 3])).allowsHitTesting(false)
                ForEach(0..<4) { index in
                    Rectangle().fill(.white).frame(width: 10, height: 10)
                        .padding(7).contentShape(Rectangle()).position(points[index])
                        .gesture(drag(.scale, size: size))
                        .accessibilityLabel("Resize visual corner \(index + 1)")
                }
                Path { path in path.move(to: top); path.addLine(to: rotate) }.stroke(.white, lineWidth: 1).allowsHitTesting(false)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11)).foregroundStyle(.black)
                    .frame(width: 20, height: 20).background(.white, in: Circle())
                    .padding(5).contentShape(Circle()).position(rotate)
                    .gesture(drag(.rotate, size: size)).accessibilityLabel("Rotate selected visual")
                Circle().stroke(.white.opacity(0.7), lineWidth: 1).frame(width: 5, height: 5).position(centre).allowsHitTesting(false)
            }.coordinateSpace(name: "transformCanvas")
                .clipped()
    }
    private enum Operation { case move, scale, rotate }
    private func corners(_ value: VisualTransform, size: CGSize) -> [CGPoint] {
        let width = store.project.width, height = store.project.height
        let matrix = value.canvasTransform(width: width, height: height)
        return [CGPoint.zero, CGPoint(x: width, y: 0), CGPoint(x: width, y: height), CGPoint(x: 0, y: height)].map {
            let point = $0.applying(matrix)
            return CGPoint(x: point.x * size.width / Double(width), y: point.y * size.height / Double(height))
        }
    }
    private func drag(_ operation: Operation, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("transformCanvas"))
            .onChanged { event in
                if origin == nil { origin = clip.transform; cancelled = false }
                guard !cancelled, let initial = origin else { return }
                var value = initial
                let ratio = Double(store.project.width) / max(1, size.width)
                let centre = CGPoint(x: size.width / 2 + initial.x / ratio, y: size.height / 2 + initial.y / ratio)
                switch operation {
                case .move:
                    value.x = min(32768, max(-32768, initial.x + event.translation.width * ratio))
                    value.y = min(32768, max(-32768, initial.y + event.translation.height * ratio))
                case .scale:
                    let start = hypot(event.startLocation.x - centre.x, event.startLocation.y - centre.y)
                    let end = hypot(event.location.x - centre.x, event.location.y - centre.y)
                    value.scale = min(4, max(0.05, initial.scale * end / max(1, start)))
                case .rotate:
                    let start = atan2(event.startLocation.y - centre.y, event.startLocation.x - centre.x)
                    let end = atan2(event.location.y - centre.y, event.location.x - centre.x)
                    let degrees = initial.rotation + Double(end - start) * 180 / Double.pi
                    value.rotation = (degrees + 540).truncatingRemainder(dividingBy: 360) - 180
                }
                store.updateCanvasTransform(value)
            }.onEnded { _ in
                if !cancelled { store.commitCanvasTransform() }
                origin = nil; cancelled = false
            }
    }
}
