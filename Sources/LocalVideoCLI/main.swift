// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import Foundation
import LocalVideoCore

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        throw EditorError("Usage: local-video probe <media> | create <project.localvideo> <media>… | validate <project> | render <project> <out.mp4>")
    }
    switch command {
    case "probe":
        guard args.count == 2 else { throw EditorError("probe needs one media path") }
        let asset = try MediaProbe.read(URL(fileURLWithPath: args[1]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(asset), as: UTF8.self))
    case "create":
        guard args.count >= 3 else { throw EditorError("create needs a project path and at least one media file") }
        var project = VideoProject()
        project.name = URL(fileURLWithPath: args[1]).deletingPathExtension().lastPathComponent
        for path in args.dropFirst(2) {
            let asset = try MediaProbe.read(URL(fileURLWithPath: path))
            project.assets.append(asset); try project.append(asset.id)
        }
        try ProjectFile.save(project, to: URL(fileURLWithPath: args[1]))
        print("Saved \(project.clips.count) visual clips + \(project.audioClips.count) audio clips · \(project.duration) seconds")
    case "validate":
        guard args.count == 2 else { throw EditorError("validate needs a project path") }
        let project = try ProjectFile.load(URL(fileURLWithPath: args[1]))
        try project.validate(requireMedia: true)
        print("Valid · \(project.clips.count) visual clips + \(project.audioClips.count) audio clips · \(project.duration) seconds")
    case "render":
        guard args.count == 3 else { throw EditorError("render needs a project and output path") }
        let project = try ProjectFile.load(URL(fileURLWithPath: args[1]))
        let job = MediaJob()
        // Keep the process alive to let MediaJob clean up its temporary output after SIGINT.
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { job.cancel() }; source.resume()
        defer { source.cancel() }
        try VideoRenderer.render(project, to: URL(fileURLWithPath: args[2]), job: job)
        print("Exported \(args[2])")
    default: throw EditorError("Unknown command: \(command)")
    }
} catch is CancellationError {
    FileHandle.standardError.write(Data("Cancelled\n".utf8)); exit(130)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
