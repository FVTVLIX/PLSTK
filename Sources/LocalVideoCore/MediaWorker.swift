// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import Foundation

public enum MediaTools {
    public static func find(_ name: String) throws -> URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        let paths = [bundled.path, "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw EditorError("\(name) is missing. Install FFmpeg or choose a build with bundled media tools.")
        }
        return URL(fileURLWithPath: path)
    }
}

/// Runs only local argument arrays. Cancellation and launch share one lock to avoid orphaned workers.
public final class MediaJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }
    public func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
    public func run(_ executable: URL, _ arguments: [String], onLine: ((String) -> Void)? = nil) throws -> Data {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close(); try? FileManager.default.removeItem(at: log) }
        let task = Process(), output = Pipe()
        task.executableURL = executable; task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output; task.standardError = logHandle
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = task
        do { try task.run(); lock.unlock() } catch { process = nil; lock.unlock(); throw error }
        var captured = Data(), pending = ""
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if let onLine {
                pending += String(decoding: chunk, as: UTF8.self)
                while let newline = pending.firstIndex(of: "\n") {
                    onLine(String(pending[..<newline])); pending.removeSubrange(...newline)
                }
            } else { captured.append(chunk) }
        }
        task.waitUntilExit()
        lock.lock(); process = nil; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard task.terminationStatus == 0 else {
            let reader = try FileHandle(forReadingFrom: log)
            defer { try? reader.close() }
            let end = try reader.seekToEnd()
            try reader.seek(toOffset: end > 8192 ? end - 8192 : 0)
            let tail = String(decoding: try reader.readToEnd() ?? Data(), as: UTF8.self)
            throw EditorError("\(executable.lastPathComponent) failed (\(task.terminationStatus)):\n\(tail)")
        }
        return captured
    }
}

public enum MediaProbe {
    public static func read(_ url: URL, job: MediaJob = MediaJob()) throws -> MediaAsset {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            throw EditorError("Choose a readable local media file.")
        }
        if let image = try stillImage(url) { return image }
        let data = try job.run(MediaTools.find("ffprobe"), ["-v", "error", "-protocol_whitelist", "file,pipe", "-show_streams", "-show_format", "-of", "json", url.path])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else { throw EditorError("Invalid media metadata.") }
        let video = streams.first { $0["codec_type"] as? String == "video" && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0 }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }
        guard let primary = video ?? audio else { throw EditorError("No video or audio found in \(url.lastPathComponent).") }
        let format = root["format"] as? [String: Any]
        let duration = Double((video == nil ? format?["duration"] as? String : nil) ?? primary["duration"] as? String ?? format?["duration"] as? String ?? "") ?? 0
        guard duration.isFinite, duration >= 1.0 / 30, duration < 1_000_000 else { throw EditorError("Unsupported media duration.") }
        let rateParts = (video?["avg_frame_rate"] as? String ?? "0/1").split(separator: "/").compactMap { Double($0) }
        let rate = rateParts.count == 2 && rateParts[1] != 0 ? rateParts[0] / rateParts[1] : 0
        let rotation = (video?["side_data_list"] as? [[String: Any]])?.compactMap { $0["rotation"] as? Int }.first ?? 0
        return MediaAsset(path: url.standardizedFileURL.path, duration: duration,
                          width: video?["width"] as? Int ?? 0, height: video?["height"] as? Int ?? 0,
                          rotation: rotation, frameRate: rate, videoStream: video?["index"] as? Int ?? -1,
                          audioStream: audio?["index"] as? Int)
    }
}

public enum VideoRenderer {
    public static func arguments(_ project: VideoProject, output: URL) throws -> [String] {
        try project.validate(requireMedia: true)
        guard !project.clips.isEmpty else { throw EditorError("Add at least one clip to the timeline.") }
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-filter_complex_threads", "1"]
        func number(_ value: Double) -> String { String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), value) }
        func seconds(_ frames: Int64) -> String { String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), Double(frames) / 30) }
        let length = seconds(project.totalFrames)
        var filters = ["color=c=black:s=\(project.width)x\(project.height):r=30:d=\(length),format=rgba[base0]"]
        var audioInputs: [String] = []
        for (index, clip) in project.clips.enumerated() {
            let asset = try project.asset(for: clip)
            guard !asset.isTitle else { throw EditorError("Use render to prepare title images before building export arguments.") }
            let start = seconds(clip.inFrame), duration = seconds(clip.frames)
            if asset.isImage {
                args += ["-protocol_whitelist", "file,pipe", "-loop", "1", "-framerate", "30", "-t", duration, "-i", asset.path]
            } else {
                args += ["-protocol_whitelist", "file,pipe", "-ss", start, "-t", duration, "-i", asset.path]
            }
            let transform = clip.transform
            let radians = number(transform.rotation * .pi / 180)
            let spatial = transform == VisualTransform() ? "" : "scale=w=\'max(2,round(iw*\(number(transform.scale))))\':h=\'max(2,round(ih*\(number(transform.scale))))\',rotate=\(radians):ow=rotw(\(radians)):oh=roth(\(radians)):c=none,"
            let imageCanvas = asset.isImage ? "pad=\(project.width):\(project.height):(ow-iw)/2:(oh-ih)/2:color=black@0," : ""
            let imageAlpha = "format=rgba,"
            var envelope = "1"
            if clip.fadeInFrames > 0 { envelope += "*min(1,max(0,(T*30+\(clip.inFrame - clip.fadeStart))/\(clip.fadeInFrames)))" }
            if clip.fadeOutFrames > 0 { envelope += "*min(1,max(0,(\(clip.fadeEnd - clip.inFrame)-T*30)/\(clip.fadeOutFrames)))" }
            var dissolve = "1"
            if clip.dissolveFrames > 0 { dissolve += "*min(1,max(0,T*30/\(clip.dissolveFrames)))" }
            let outgoing = project.outgoingDissolve(clip.id)
            if outgoing > 0 { dissolve += "*min(1,max(0,(\(clip.frames)-T*30)/\(outgoing)))" }
            let animation = envelope == "1" && dissolve == "1" ? "" : ",format=gbrap,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='alpha(X,Y)*\(envelope)*\(dissolve)'"
            let input = "[\(index):\(asset.videoStream)]setpts=PTS-STARTPTS,\(imageAlpha)scale=\(project.width):\(project.height):force_original_aspect_ratio=decrease:force_divisible_by=2,\(imageCanvas)setsar=1,fps=30,tpad=stop_mode=clone:stop_duration=1,trim=end_frame=\(clip.frames),setpts=N/(30*TB),format=rgba,\(spatial)colorchannelmixer=aa=\(number(clip.opacity))\(animation)"
            if project.hasDissolves {
                filters.append(input + "[raw\(index)]")
                filters.append("color=c=black@0:s=\(project.width)x\(project.height):r=30:d=\(duration),format=rgba[clear\(index)]")
                filters.append("[clear\(index)][raw\(index)]overlay=x='(W-w)/2+\(number(transform.x))':y='(H-h)/2+\(number(transform.y))':format=auto:shortest=1,format=gbrap,premultiply=inplace=1,tpad=start_duration=\(seconds(project.position(of: clip))):stop_duration=\(length):color=black@0,trim=end_frame=\(project.totalFrames),setpts=N/(30*TB)[v\(index)]")
            } else { filters.append(input + ",setpts=PTS+\(seconds(project.position(of: clip)))/TB[v\(index)]") }
            if let stream = asset.audioStream {
                let gain = clip.muted ? 0 : project.videoVolume
                let expression = dissolve.replacingOccurrences(of: "T", with: "t")
                let audioFade = dissolve == "1" ? "" : "aeval=exprs='val(0)*\(expression)|val(1)*\(expression)',"
                filters.append("[\(index):\(stream)]aresample=48000:async=1:first_pts=0,aformat=sample_fmts=fltp:channel_layouts=stereo,apad,atrim=duration=\(duration),asetpts=N/SR/TB,volume=\(gain),\(audioFade)adelay=\(project.position(of: clip) * 1600)S:all=1[va\(index)]")
                audioInputs.append("[va\(index)]")
            }
        }
        let ordered = project.clips.indices.sorted { project.clips[$0].lane < project.clips[$1].lane }
        var stages = 0
        if project.hasDissolves {
            for lane in Set(project.clips.map(\.lane)).sorted() {
                let entries = ordered.filter { project.clips[$0].lane == lane }
                var input = "v\(entries[0])"
                for index in entries.dropFirst() {
                    let next = "sum\(lane)_\(index)"
                    filters.append("[\(input)][v\(index)]blend=all_mode=addition:shortest=1[\(next)]"); input = next
                }
                filters.append("[\(input)]unpremultiply=inplace=1,format=rgba[lane\(lane)]")
                filters.append("[base\(stages)][lane\(lane)]overlay=0:0:format=rgb:eof_action=pass:repeatlast=0[base\(stages + 1)]")
                stages += 1
            }
        } else {
            for index in ordered {
                let clip = project.clips[index], start = project.position(of: project.clips[index])
                filters.append("[base\(stages)][v\(index)]overlay=x='(W-w)/2+\(number(clip.transform.x))':y='(H-h)/2+\(number(clip.transform.y))':format=rgb:eof_action=pass:repeatlast=0:enable='gte(t,\(seconds(start)))*lt(t,\(seconds(start + clip.frames)))'[base\(stages + 1)]")
                stages += 1
            }
        }
        filters.append("[base\(stages)]trim=end_frame=\(project.totalFrames),setpts=N/(30*TB),scale=out_color_matrix=bt709,format=yuv420p,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709[v]")
        filters.append("anullsrc=r=48000:cl=stereo,atrim=duration=\(length)[silence]")
        audioInputs.append("[silence]")
        for (offset, clip) in project.audioClips.enumerated() {
            let media = project.assets.first { $0.id == clip.assetID }!
            let index = project.clips.count + offset
            let start = String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), Double(clip.inFrame) / 30)
            let duration = String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), Double(clip.frames) / 30)
            args += ["-protocol_whitelist", "file,pipe", "-ss", start, "-t", duration, "-i", media.path]
            let delaySamples = clip.startFrame * 1600
            var envelope = "1"
            if clip.fadeInFrames > 0 {
                envelope += "*min(1,max(0,(t*30+\(clip.inFrame - clip.fadeStart))/\(clip.fadeInFrames)))"
            }
            if clip.fadeOutFrames > 0 {
                envelope += "*min(1,max(0,(\(clip.fadeEnd - clip.inFrame)-t*30)/\(clip.fadeOutFrames)))"
            }
            let fade = clip.fadeInFrames == 0 && clip.fadeOutFrames == 0 ? "" : "aeval=exprs='val(0)*\(envelope)|val(1)*\(envelope)',"
            filters.append("[\(index):\(media.audioStream!)]aresample=48000:async=1:first_pts=0,aformat=sample_fmts=fltp:channel_layouts=stereo,apad,atrim=duration=\(duration),asetpts=N/SR/TB,volume=\(clip.effectiveVolume),\(fade)adelay=\(delaySamples)S:all=1[overlay\(offset)]")
            audioInputs.append("[overlay\(offset)]")
        }
        filters.append("\(audioInputs.joined())amix=inputs=\(audioInputs.count):duration=longest:normalize=0,atrim=duration=\(length)[a]")
        args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[v]", "-map", "[a]",
                 "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-map_metadata", "-1",
                 "-progress", "pipe:1", "-nostats", "-f", "mp4", output.path]
        return args
    }
    public static func render(_ project: VideoProject, to output: URL, job: MediaJob,
                              progress: @escaping (Double) -> Void = { _ in }) throws {
        guard output.isFileURL else { throw EditorError("Choose a local export destination.") }
        let destination = output.standardizedFileURL.resolvingSymlinksInPath()
        guard !project.assets.contains(where: { !$0.isTitle && URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == destination }) else {
            throw EditorError("Export cannot overwrite a source media file.")
        }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try project.validate(requireMedia: true)
        var prepared = project
        let images = try PreviewResources()
        var normalizedImages: [String: MediaAsset] = [:]
        for index in prepared.clips.indices {
            let clip = prepared.clips[index]
            let asset = try project.asset(for: clip)
            guard asset.isImage else { continue }
            let key = "\(asset.id)-\(clip.imageTransparency)"
            if normalizedImages[key] == nil {
                let path = try StillImage.normalized(asset, width: project.width, height: project.height,
                    directory: images.directory, preserveAlpha: clip.imageTransparency).path
                let normalized = MediaAsset(path: path, duration: asset.duration,
                    width: project.width, height: project.height, isImage: true)
                normalizedImages[key] = normalized
                prepared.assets.append(normalized)
            }
            prepared.clips[index].assetID = normalizedImages[key]!.id
            try job.checkCancellation()
        }
        defer { withExtendedLifetime(images) {} }
        let args = try arguments(prepared, output: temporary)
        _ = try job.run(MediaTools.find("ffmpeg"), args) { line in
            if line.hasPrefix("out_time_us="), let value = Double(line.dropFirst(12)) {
                progress(min(0.99, max(0, value / 1_000_000 / project.duration)))
            }
        }
        try job.checkCancellation()
        // POSIX rename on the same volume publishes atomically, preserving an old output on render failure.
        guard rename(temporary.path, output.path) == 0 else { throw EditorError("Could not publish export: \(String(cString: strerror(errno))).") }
        progress(1)
    }
}
