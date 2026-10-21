// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVKit
import LocalVideoCore
import SwiftUI

/// Owns a separate composition and player. Reviewing never borrows the editor's
/// player, playhead, undo history, or project mutation path.
@MainActor final class DirectorDraftPlayer: ObservableObject {
    typealias Builder = (VideoProject) async throws -> TimelinePreview
    @Published private(set) var player: AVPlayer?
    @Published private(set) var loading = false
    @Published private(set) var problem: String?
    private let build: Builder
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var statusObserver: NSKeyValueObservation?

    init(build: @escaping Builder = { try await TimelinePreview.build($0) }) { self.build = build }

    func prepare(_ project: VideoProject) {
        stop()
        loading = true
        let current = generation, build = build
        task = Task { [weak self] in
            do {
                let preview = try await build(project)
                try Task.checkCancellation()
                guard let self, self.generation == current else { return }
                let item = preview.playerItem(), player = AVPlayer()
                player.actionAtItemEnd = .pause
                self.player = player
                self.statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
                    Task { @MainActor in
                        guard let self, self.generation == current, let item,
                              self.player?.currentItem === item else { return }
                        switch item.status {
                        case .readyToPlay: self.loading = false
                        case .failed:
                            self.releasePlayer()
                            self.loading = false
                            self.problem = "Draft playback is unavailable for this media. You can return to the editor and review the proposal there."
                        default: break
                        }
                    }
                }
                player.replaceCurrentItem(with: item)
                self.task = nil
            } catch {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.loading = false
                self.problem = "Couldn’t prepare draft playback. Check that the source media is available, then try again."
                self.task = nil
            }
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        releasePlayer()
        loading = false; problem = nil
    }

    private func releasePlayer() {
        statusObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    deinit { task?.cancel() }
}

struct DirectorDraftPlayback: View {
    let draft: DirectorDraft
    @ObservedObject var store: EditorStore
    @ObservedObject var director: DirectorController
    @StateObject private var playback = DirectorDraftPlayer()
    @Environment(\.dismiss) private var dismiss

    private var current: Bool { director.pending?.id == draft.id && store.project == draft.base }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Watch draft", systemImage: "play.rectangle").font(.title2.weight(.semibold))
                Spacer()
                Button("Back to editor") { close() }.keyboardShortcut(.cancelAction)
            }
            Text("Check the motion and sound. Your timeline stays unchanged until you apply this draft.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ZStack {
                Color.black
                if let player = playback.player { DraftPlayerSurface(player: player) }
                if playback.loading {
                    VStack(spacing: 10) { ProgressView(); Text("Preparing draft playback…").font(.system(size: 12)) }
                        .padding(20).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                }
                if let problem = playback.problem {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.title2)
                        Text(problem).font(.system(size: 12)).multilineTextAlignment(.center)
                        Button("Try again") { playback.prepare(draft.project) }
                    }.padding(24).frame(maxWidth: 420)
                }
            }
            .frame(height: 350).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Button {
                    guard let player = playback.player else { return }
                    if player.rate != 0 { player.pause() }
                    else {
                        if player.currentTime().seconds >= draft.project.duration - 1.0 / 30 {
                            player.seek(to: .zero)
                        }
                        player.play()
                    }
                } label: { Label("Play / pause", systemImage: "playpause") }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(playback.loading || playback.player == nil)
                Label("Local preview", systemImage: "desktopcomputer").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Apply draft") {
                    guard current else { close(); return }
                    playback.stop()
                    director.apply(to: store)
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(!current || store.busy || director.working)
            }
        }
        .padding(22).frame(width: 700).preferredColorScheme(.dark)
        .onAppear { store.player?.pause(); playback.prepare(draft.project) }
        .onDisappear { playback.stop() }
        .onChange(of: current) { _, valid in if !valid { close() } }
    }
    private func close() { playback.stop(); dismiss() }
}

private struct DraftPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
