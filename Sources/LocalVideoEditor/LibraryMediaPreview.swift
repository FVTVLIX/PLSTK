// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVKit
import LocalVideoCore
import SwiftUI

/// Source playback is independent of the timeline, so browsing never inserts an edit.
struct LibraryMediaPreview: View {
    let media: MediaAsset
    let addToTimeline: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(media.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text("\(media.isImage ? "Image" : (media.isAudioOnly ? "Audio" : "Video")) · \(durationLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    player?.pause()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Close preview")
                .accessibilityLabel("Close preview")
            }

            ZStack {
                Color.black
                if media.isImage, let image = NSImage(contentsOfFile: media.path) {
                    Image(nsImage: image).resizable().scaledToFit()
                }
                if media.isAudioOnly {
                    Image(systemName: "waveform")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.bottom, 24)
                }
                if let player {
                    LibrarySourcePlayer(player: player)
                }
            }
            .frame(height: media.isAudioOnly ? 160 : 210)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Text("Source preview")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    player?.pause()
                    addToTimeline()
                    dismiss()
                } label: {
                    Label("Add to timeline", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(Color(white: 0.08))
        .preferredColorScheme(.dark)
        .onAppear(perform: loadSource)
        .onChange(of: media.id) { _, _ in loadSource() }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
    }

    private var durationLabel: String {
        let seconds = Int(max(0, media.duration).rounded(.down))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func loadSource() {
        player?.pause()
        guard !media.isImage else { player = nil; return }
        player = AVPlayer(url: URL(fileURLWithPath: media.path))
    }
}

private struct LibrarySourcePlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
