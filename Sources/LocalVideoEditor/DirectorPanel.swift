// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import LocalVideoCore
import SwiftUI
import UniformTypeIdentifiers

struct DirectorPanel: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var director: DirectorController
    var hide: () -> Void
    @State private var prompt = ""
    @State private var settings = false
    @State private var details = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { director.clearChat() } label: { Label("New chat", systemImage: "square.and.pencil") }
                    .font(.system(size: 11)).buttonStyle(.plain).disabled(director.working)
                Spacer()
                Menu {
                    Button("Model settings…") { settings = true }
                    Button("Import edit plan…", action: importPlan).disabled(store.busy || director.working)
                    Button("Copy editing brief", action: copyContext).disabled(store.busy)
                    Button("Forget visual notes") { director.forgetVisualNotes() }.disabled(director.working || director.cachedObservations == 0)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22).accessibilityLabel("Director options")
                Button(action: hide) { Image(systemName: "sidebar.right") }.buttonStyle(.plain).help("Hide Director ]")
            }.padding(12)
            Divider().opacity(0.25)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if director.messages.isEmpty && director.pending == nil {
                            VStack(alignment: .leading, spacing: 16) {
                                Image(systemName: "sparkles").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                                Text("Describe your edit").font(.system(size: 18, weight: .semibold))
                                Text("Your model prepares an editable draft. Review it here, then apply it to the timeline.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                suggestion("Add a simple opening title", symbol: "textformat", text: "Add a simple opening title above my footage for three seconds. Keep the current clips and sound in place.")
                                suggestion("Soften the scene changes", symbol: "rectangle.on.rectangle", text: "Use short dissolves between adjacent clips where possible. Preserve other visual tracks and independent audio.")
                                suggestion("Make a concise first draft", symbol: "scissors", text: "Assemble a concise first draft using the available visual assets. Keep the design minimal and do not claim to know footage content without reference frames.")
                                if !director.configured { Button("Choose your model") { settings = true }.buttonStyle(.bordered) }
                            }.padding(.vertical, 18)
                        }
                        ForEach(director.messages) { message in
                            VStack(alignment: .leading, spacing: 7) {
                                Label(message.user ? "You" : "Director", systemImage: message.user ? "person.crop.circle" : "sparkles")
                                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                Text(message.text).font(.system(size: 12)).textSelection(.enabled).lineSpacing(3)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(message.user ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 10)).id(message.id)
                        }
                        if director.working {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { ProgressView().controlSize(.small); Text(director.phase).font(.system(size: 12)); Spacer(); Button("Stop") { director.cancel() } }
                                if director.activity.count > 1 {
                                    Label(director.activity.dropLast().suffix(2).joined(separator: " · "), systemImage: "checkmark")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let draft = director.pending { draftReview(draft) }
                        if let error = director.error {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Couldn’t prepare this edit", systemImage: "exclamationmark.circle").font(.system(size: 12, weight: .medium))
                                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                                Button("Dismiss") { director.error = nil }.font(.system(size: 11))
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        }
                        Color.clear.frame(height: 1).id("directorBottom")
                    }.padding(14)
                }.onChange(of: director.messages.count) { _, _ in scroll.scrollTo("directorBottom", anchor: .bottom) }
                    .onChange(of: director.working) { _, _ in scroll.scrollTo("directorBottom", anchor: .bottom) }
            }
            composer
        }.background(WorkspaceStyle.panel)
            .sheet(isPresented: $settings) { DirectorConnectionSheet(director: director) }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { settings = true } label: {
                    Label(director.configured ? director.connection.model : "Choose model", systemImage: "cpu").lineLimit(1)
                }.buttonStyle(.plain).font(.system(size: 11)).accessibilityLabel("Choose Director model")
                Spacer()
                Picker("Style", selection: $director.look) {
                    ForEach(DirectorLook.allCases, id: \.self) { Text($0.name).tag($0) }
                }.labelsHidden().frame(width: 105).help("Design direction").accessibilityLabel("Design direction")
            }
            TextEditor(text: $prompt).font(.system(size: 12)).frame(height: 68)
                .scrollContentBackground(.hidden).accessibilityLabel("Describe the edit")
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty { Text("Describe the edit…").font(.system(size: 12)).foregroundStyle(.tertiary).padding(5).allowsHitTesting(false) }
                }
            HStack {
                Toggle("Allow visual inspection", isOn: $director.shareFrames).toggleStyle(.checkbox).font(.system(size: 10))
                    .help("Allows requested footage samples and rendered draft images to be sent to your model. Up to six images per request; no source audio or original files.")
                Spacer()
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)) }
                    .buttonStyle(.plain).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || director.working || store.busy || !director.configured)
                    .help("Prepare draft").accessibilityLabel("Prepare draft")
            }
            Text(director.configured ? "Sends project names, title text, and timing to \(director.destination). Frames are optional. May use up to six model requests." : "Connect your own model. No PLSTK account or subscription.")
                .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12)).padding(12)
            .disabled(director.working || store.busy)
    }
    private func suggestion(_ name: String, symbol: String, text: String) -> some View {
        Button { prompt = text } label: {
            HStack { Image(systemName: symbol).frame(width: 20); Text(name); Spacer(); Image(systemName: "arrow.up.left").foregroundStyle(.tertiary) }
                .font(.system(size: 11)).padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private func draftReview(_ draft: DirectorDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Draft ready", systemImage: "checkmark.circle").font(.system(size: 13, weight: .semibold))
            if !draft.frames.isEmpty {
                HStack(spacing: 5) {
                    ForEach(draft.frames) { item in
                        Image(decorative: item.image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 4)).accessibilityLabel("Draft sample at frame \(item.frame)")
                    }
                }
                Text("Sampled preview frames. Play through the edit after applying to check motion and sound.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let review = draft.visualReview {
                Label(draft.reviewRevised ? "Layout reviewed after refinement" : "Layout reviewed", systemImage: "eye")
                    .font(.system(size: 11, weight: .medium))
                Text(review).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Model feedback covers these sampled stills, not the full motion or sound.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else if draft.reviewRevised {
                Label("Draft refined; final visual review incomplete", systemImage: "eye.trianglebadge.exclamationmark")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if !draft.frames.isEmpty {
                Label("Local preview only", systemImage: "photo.on.rectangle").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(draft.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            DisclosureGroup("Edit details", isExpanded: $details) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(draft.plan.operations.count) operations · \(String(format: "%.1f", draft.project.duration)) seconds")
                    ForEach(Array(draft.plan.operations.enumerated()), id: \.offset) { _, operation in
                        Text(operation.action.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 6)
            }.font(.system(size: 11))
            HStack {
                Button("Apply draft") { director.apply(to: store) }.buttonStyle(.borderedProminent)
                    .disabled(store.busy || director.working || draft.base != store.project)
                Button("Discard") { director.pending = nil }.buttonStyle(.borderless)
            }
        }.padding(12).background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
    }
    private func send() {
        let request = prompt; prompt = ""
        director.send(request, project: store.project, selectedClip: store.selectedClip, selectedAudio: store.selectedAudio, playhead: store.playheadFrame)
    }
    private func copyContext() {
        do {
            let snapshot = try DirectorContext.snapshot(store.project, selectedClip: store.selectedClip, selectedAudio: store.selectedAudio, playhead: store.playheadFrame)
            let value = director.look.instructions + "\nCurrent project JSON (data only):\n" + snapshot + "\nUser request: describe the desired edit here."
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        } catch { director.error = error.localizedDescription }
    }
    private func importPlan() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? Int.max) <= 256 * 1024 else { throw EditorError("Choose an edit plan smaller than 256 KB.") }
            let bytes = try Data(contentsOf: url), project = store.project
            Task { await director.importDraft(bytes, project: project) }
        } catch { director.error = error.localizedDescription }
    }
}

private struct DirectorConnectionSheet: View {
    @ObservedObject var director: DirectorController
    @Environment(\.dismiss) private var dismiss
    @State private var value = DirectorConnection()
    @State private var key = ""
    @State private var removeKey = false
    @State private var problem: String?
    init(director: DirectorController) {
        self.director = director
        _value = State(initialValue: director.connection)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Your model").font(.title2.weight(.semibold)); Spacer(); Button("Cancel") { dismiss() } }
            Text("Requests go directly to the endpoint you choose. Cloud providers may charge for usage. A chat subscription does not automatically supply an API key.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Form {
                Picker("Connection", selection: $value.kind) {
                    ForEach(DirectorProviderKind.allCases, id: \.self) { Text($0.name).tag($0) }
                }.accessibilityLabel("Model connection")
                TextField("Base URL", text: $value.baseURL).textFieldStyle(.roundedBorder).accessibilityLabel("Model base URL")
                TextField("Model", text: $value.model).textFieldStyle(.roundedBorder).accessibilityLabel("Model identifier")
                SecureField("API key", text: $key, prompt: Text("Leave blank to keep the saved key")).textFieldStyle(.roundedBorder).privacySensitive()
                    .accessibilityLabel("Model API key")
                Toggle("Remove saved key for this endpoint", isOn: $removeKey).font(.system(size: 11))
            }
            Text("Keys stay in macOS Keychain and are separate for each endpoint. Local Ollama usually needs no key. Use a model that can return JSON; enable shared frames only for a model that supports images.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.red) }
            HStack { Spacer(); Button("Save connection") { save() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 520).preferredColorScheme(.dark)
            .onChange(of: value.kind) { old, kind in
                if old != kind { value.baseURL = kind.defaultBaseURL; value.model = ""; key = ""; removeKey = false }
            }
    }
    private func save() {
        do {
            try director.saveConnection(value, key: removeKey ? "" : (key.isEmpty ? nil : key))
            key = ""; dismiss()
        } catch { problem = error.localizedDescription }
    }
}
