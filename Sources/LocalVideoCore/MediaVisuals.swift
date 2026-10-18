// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVFoundation
import Foundation

/// The file identity prevents stale pictures after a source is replaced or relinked.
public struct MediaVisualSource: Hashable, Sendable {
    public let path: String
    public let duration: Double
    public let audioStream: Int?
    public let isImage: Bool
    public let title: TextTitle?
    private let size: UInt64
    private let modified: Double
    private let inode: UInt64
    public init(_ media: MediaAsset) throws {
        guard media.duration.isFinite, media.duration > 0, media.duration < 1_000_000,
              media.audioStream.map({ $0 >= 0 }) ?? true else { throw EditorError("Invalid media metadata for visuals.") }
        title = media.title
        if media.isTitle {
            path = "title:\(media.id)"; duration = media.duration; audioStream = nil; isImage = true
            size = 0; modified = 0; inode = 0
            return
        }
        let url = URL(fileURLWithPath: media.path).standardizedFileURL.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        isImage = media.isImage
        path = url.path; duration = media.duration; audioStream = media.audioStream
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

public struct AudioWaveform: Sendable {
    public let secondsPerPeak: Double
    public let peaks: [Float]
    public func peak(from start: Double, to end: Double) -> Float {
        guard start.isFinite, end.isFinite, end > start, secondsPerPeak > 0 else { return 0 }
        let lower = Int(max(0, min(Double(peaks.count), floor(start / secondsPerPeak))))
        let upper = Int(max(0, min(Double(peaks.count), ceil(end / secondsPerPeak))))
        guard lower < upper else { return 0 }
        return peaks[lower..<upper].max() ?? 0
    }
}

private final class WaveformBox: NSObject {
    let value: AudioWaveform
    init(_ value: AudioWaveform) { self.value = value }
}

/// Synchronous shutdown is needed because NSApplication may terminate before
/// an actor task gets another turn to stop its media subprocess.
private final class VisualWorkers: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var jobs: [UUID: MediaJob] = [:]
    func register(_ job: MediaJob, id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if closed { job.cancel() } else { jobs[id] = job }
    }
    func remove(_ id: UUID) { lock.lock(); jobs[id] = nil; lock.unlock() }
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        for job in jobs.values { job.cancel() }
    }
}

/// Bounded memory caches with coalesced requests. Each decoder queue is serial;
/// a long waveform job cannot block thumbnail decoding or the main thread.
public actor MediaVisualCache {
    public static let shared = MediaVisualCache()
    private nonisolated let workers = VisualWorkers()
    private struct ThumbnailKey: Hashable { let source: MediaVisualSource; let frame: Int64 }
    private let images = NSCache<NSString, CGImage>()
    private let waveforms = NSCache<NSString, WaveformBox>()
    private var imageJobs: [ThumbnailKey: Task<CGImage, Error>] = [:]
    private var waveformJobs: [MediaVisualSource: Task<AudioWaveform, Error>] = [:]
    private var imageTail: Task<Void, Never>?
    private var waveformTail: Task<Void, Never>?
    public init() {
        images.totalCostLimit = 48 * 1024 * 1024; images.countLimit = 512
        waveforms.totalCostLimit = 8 * 1024 * 1024; waveforms.countLimit = 128
    }
    private func key(_ source: MediaVisualSource) -> String { String(reflecting: source) }

    public func thumbnail(_ source: MediaVisualSource, frame: Int64) async throws -> CGImage {
        let frame = source.isImage ? 0 : max(0, min(Int64(floor(source.duration * 30)) - 1, frame))
        let request = ThumbnailKey(source: source, frame: frame)
        let cacheKey = (key(source) + ":\(frame)") as NSString
        if let image = images.object(forKey: cacheKey) { return image }
        if let job = imageJobs[request] { return try await job.value }
        let previous = imageTail
        let job = Task.detached(priority: .utility) {
            await previous?.value
            try Task.checkCancellation()
            if let title = source.title { return try title.raster(width: 192, height: 108) }
            if source.isImage { return try StillImage.decoded(URL(fileURLWithPath: source.path), maxSize: 192) }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: source.path)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 192, height: 108)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
            return try await withTaskCancellationHandler {
                try await generator.image(at: CMTime(value: frame, timescale: 30)).image
            } onCancel: { generator.cancelAllCGImageGeneration() }
        }
        imageJobs[request] = job
        imageTail = Task { _ = await job.result }
        do {
            let image = try await job.value
            imageJobs[request] = nil
            images.setObject(image, forKey: cacheKey, cost: image.bytesPerRow * image.height)
            return image
        } catch { imageJobs[request] = nil; throw error }
    }

    public func waveform(_ source: MediaVisualSource) async throws -> AudioWaveform {
        guard let stream = source.audioStream else { return AudioWaveform(secondsPerPeak: 1, peaks: []) }
        let cacheKey = key(source) as NSString
        if let box = waveforms.object(forKey: cacheKey) { return box.value }
        if let job = waveformJobs[source] { return try await job.value }
        let previous = waveformTail, workers = workers
        let job = Task.detached(priority: .utility) {
            await previous?.value
            try Task.checkCancellation()
            let worker = MediaJob(), id = UUID()
            workers.register(worker, id: id)
            defer { workers.remove(id) }
            return try await withTaskCancellationHandler {
                // Stream metadata rather than retaining a potentially hours-long PCM buffer.
                let window = max(80, Int(ceil(source.duration * 8000 / 16_384)))
                let secondsPerPeak = Double(window) / 8000
                let count = Int(ceil(source.duration / secondsPerPeak))
                var peaks = [Float](repeating: 0, count: count)
                var time = 0.0
                let filters = "aresample=8000:async=1:first_pts=0,asetnsamples=n=\(window):p=1,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.Peak_level:file='pipe\\:1'"
                _ = try worker.run(MediaTools.find("ffmpeg"), ["-v", "error", "-nostdin", "-protocol_whitelist", "file,pipe", "-i", source.path,
                    "-map", "0:\(stream)", "-vn", "-t", String(source.duration), "-af", filters, "-f", "null", "-"]) { line in
                    if let range = line.range(of: "pts_time:"), let value = Double(line[range.upperBound...]) { time = value }
                    if line.hasPrefix("lavfi.astats.Overall.Peak_level="), let value = Double(line.split(separator: "=").last ?? "") {
                        let index = Int((time / secondsPerPeak).rounded())
                        if peaks.indices.contains(index) { peaks[index] = value.isFinite ? Float(min(1, pow(10, value / 20))) : 0 }
                    }
                }
                try Task.checkCancellation()
                return AudioWaveform(secondsPerPeak: secondsPerPeak, peaks: peaks)
            } onCancel: { worker.cancel() }
        }
        waveformJobs[source] = job
        waveformTail = Task { _ = await job.result }
        do {
            let waveform = try await job.value
            waveformJobs[source] = nil
            waveforms.setObject(WaveformBox(waveform), forKey: cacheKey, cost: waveform.peaks.count * MemoryLayout<Float>.size)
            return waveform
        } catch { waveformJobs[source] = nil; throw error }
    }
    public nonisolated func stopWorkers() { workers.shutdown() }

    public func retainSources(_ sources: Set<MediaVisualSource>) {
        for (key, job) in imageJobs where !sources.contains(key.source) { job.cancel() }
        for (key, job) in waveformJobs where !sources.contains(key) { job.cancel() }
    }

    public func cancelAll() {
        for job in imageJobs.values { job.cancel() }
        for job in waveformJobs.values { job.cancel() }
        // Leave entries until their waiters drain; new source requests are not discarded.
    }
}
