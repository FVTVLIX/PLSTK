// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import Foundation
import LocalVideoCore

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        throw EditorError("Usage: local-video probe <media> | create <project.localvideo> <media>… | validate <project> | render <project> <out.mp4> | director-context <project> | director-contract | check-plan <project> <plan.json> | apply-plan <project> <plan.json> <revision>")
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
    case "director-context":
        guard args.count == 2 else { throw EditorError("director-context needs one project path") }
        print(try DirectorContext.snapshot(ProjectFile.load(URL(fileURLWithPath: args[1]))))
    case "director-contract":
        guard args.count == 1 else { throw EditorError("director-contract needs no arguments") }
        print(DirectorLook.minimal.instructions)
    case "check-plan", "apply-plan":
        guard args.count == (command == "apply-plan" ? 4 : 3) else { throw EditorError("Use check-plan <project> <plan.json> or apply-plan <project> <plan.json> <revision>") }
        let url = URL(fileURLWithPath: args[1]), planURL = URL(fileURLWithPath: args[2])
        let original = try ProjectFile.load(url), revision = try DirectorContext.revision(original)
        if command == "apply-plan", args[3] != revision { throw EditorError("The project changed. Read its context and check a fresh plan before applying.") }
        let size = try planURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 262_144 else { throw EditorError("Choose an edit plan smaller than 256 KB.") }
        let plan = try DirectorPlan.decode(Data(contentsOf: planURL))
        let candidate = try plan.applying(to: original)
        if command == "apply-plan" {
            // Recheck immediately before the atomic save, which preserves the previous file as a backup.
            guard try DirectorContext.revision(ProjectFile.load(url)) == revision else { throw EditorError("The project changed before the draft could be saved.") }
            try ProjectFile.save(candidate, to: url)
        }
        let result: [String: Any] = ["summary": plan.summary, "operationCount": plan.operations.count,
            "baseRevision": revision, "durationSeconds": candidate.duration,
            "warnings": DirectorContext.warnings(candidate), "applied": command == "apply-plan"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
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
