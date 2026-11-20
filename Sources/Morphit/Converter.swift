import AppKit
import Foundation
import Observation

/// One file in the list.
@MainActor @Observable
final class Job: Identifiable {
    enum Status: Equatable {
        case ready
        case waiting
        case running(Double?)          // fraction done, nil when unknown
        case done(URL)
        case failed(String)
        case skipped(String)
        case cancelled
    }

    let id = UUID()
    let url: URL
    /// From the file type; for types macOS doesn't know, from ffprobe once the file has been read.
    var kind: MediaKind?
    var status: Status = .ready
    var detail = ""                    // "1920×1080 · 2:31" once read
    var note: String?                  // an adaptation worth knowing ("Mixed down to stereo…")
    var trashed = false

    init(url: URL) {
        self.url = url
        kind = mediaKind(of: url)
    }

    var isFinished: Bool {
        switch status {
        case .done, .failed, .skipped, .cancelled: true
        default: false
        }
    }
    var isActive: Bool {
        switch status {
        case .waiting, .running: true
        default: false
        }
    }
}

/// Names the output after the original, next to it or in the chosen folder. An existing file is
/// never overwritten: the new one gets " 2", " 3"…
func outputURL(for input: URL, format: OutputFormat, folder: URL?, reserved: Set<String>) -> URL {
    let dir = folder ?? input.deletingLastPathComponent()
    let base = input.deletingPathExtension().lastPathComponent
    let ext = format.fileExtension
    var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
    var n = 2
    while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) {
        candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
        n += 1
    }
    return candidate
}

/// Converts a list of files with one template, several at a time according to the CPU level.
@MainActor @Observable
final class Converter {
    static let shared = Converter()

    var jobs: [Job] = []
    private(set) var isRunning = false
    private var runTask: Task<Void, Never>?
    /// Output names taken by conversions in progress (not on disk yet).
    private var reserved = Set<String>()

    var finishedCount: Int { jobs.filter(\.isFinished).count }
    var failedCount: Int { jobs.filter { if case .failed = $0.status { true } else { false } }.count }
    var doneCount: Int { jobs.filter { if case .done = $0.status { true } else { false } }.count }

    /// Overall progress of the current batch (0…1).
    var overallProgress: Double {
        let batch = jobs.filter { $0.status != .ready }
        guard !batch.isEmpty else { return 0 }
        let sum = batch.reduce(0.0) { acc, j in
            switch j.status {
            case .running(let f): acc + (f ?? 0)
            case .done, .failed, .skipped, .cancelled: acc + 1
            default: acc
            }
        }
        return sum / Double(batch.count)
    }

    // MARK: Adding files

    func add(_ urls: [URL]) {
        var existing = Set(jobs.map { $0.url.standardizedFileURL.path })
        var added: [Job] = []
        for url in expand(urls) where existing.insert(url.standardizedFileURL.path).inserted {
            let j = Job(url: url)
            jobs.append(j)
            added.append(j)
        }
        describeLater(added)
    }

    /// Reads size, codec and duration of new files in the background, one after the other.
    private func describeLater(_ list: [Job]) {
        guard !list.isEmpty else { return }
        Task {
            for j in list where j.detail.isEmpty && jobs.contains(where: { $0.id == j.id }) {
                if j.kind == .image, j.url.pathExtension.lowercased() != "gif" {
                    let url = j.url
                    if let i = await Task.detached(priority: .utility, operation: { ImageConvert.info(url) }).value {
                        j.detail = "\(i.width)×\(i.height)"
                    }
                } else if let info = try? await Probe.run(j.url), info.video != nil || !info.audio.isEmpty {
                    if j.kind == nil { j.kind = info.video != nil ? .video : .audio }
                    if j.detail.isEmpty { j.detail = describe(info) }
                } else if j.kind == nil {
                    j.detail = "Not an audio, video or image file"
                }
            }
        }
    }

    /// Files as they are; folders searched recursively for audio, video and images.
    private func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue && !url.pathExtension.lowercased().hasSuffix("bundle") {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
                var found: [URL] = []
                while let f = e?.nextObject() as? URL {
                    if (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, mediaKind(of: f) != nil { found.append(f) }
                }
                out += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else {
                out.append(url)
            }
        }
        return out
    }

    func remove(_ job: Job) {
        guard !job.isActive else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() { jobs.removeAll { $0.isFinished } }
    func clearAll() { if !isRunning { jobs.removeAll() } }

    // MARK: Running

    /// Files waiting for a free slot, each with the template of its group.
    private var queue: [(Job, ConversionTemplate)] = []
    private var batch: [Job] = []

    static func startable(_ j: Job) -> Bool {
        switch j.status {
        case .ready, .failed, .cancelled, .skipped: true
        default: false
        }
    }

    /// Converts these files with `template` (failed and stopped ones are tried again). While a
    /// conversion is running, they join the queue.
    func enqueue(_ list: [Job], _ template: ConversionTemplate) {
        let todo = list.filter(Self.startable)
        guard !todo.isEmpty else { return }
        for j in todo { j.status = .waiting; j.note = nil; queue.append((j, template)) }
        batch += todo
        if !isRunning { run() }
    }

    private func run() {
        isRunning = true
        let cpu = Prefs.cpu
        let folder = Prefs.outputFolder
        let trash = Prefs.trashOriginals
        Notifier.prepare()
        runTask = Task {
            await withTaskGroup(of: Void.self) { group in
                func launch() async {
                    guard let (job, t) = await self.takeNext() else { return }
                    group.addTask { await self.convert(job, t, cpu: cpu, folder: folder, trash: trash) }
                }
                for _ in 0..<cpu.parallelJobs { await launch() }
                while await group.next() != nil {
                    if Task.isCancelled { continue }
                    await launch()
                }
            }
            for (j, _) in queue where j.status == .waiting { j.status = .cancelled }
            queue.removeAll()
            let finished = batch
            batch = []
            isRunning = false
            let ok = finished.filter { if case .done = $0.status { true } else { false } }.count
            let bad = finished.filter { if case .failed = $0.status { true } else { false } }.count
            if !Task.isCancelled {
                Notifier.notify(bad == 0 ? "Conversion finished" : "Conversion finished with errors",
                                bad == 0 ? "\(ok) \(ok == 1 ? "file" : "files") converted." : "\(ok) converted, \(bad) failed.")
            }
        }
    }

    private func takeNext() -> (Job, ConversionTemplate)? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    func stop() {
        runTask?.cancel()
    }

    /// Removes the group's files that aren't converting.
    func clear(_ list: [Job]) {
        let ids = Set(list.filter { !$0.isActive }.map(\.id))
        jobs.removeAll { ids.contains($0.id) }
    }

    private func convert(_ job: Job, _ t: ConversionTemplate, cpu: CPULevel, folder: URL?, trash: Bool) async {
        guard !Task.isCancelled else { return }
        job.status = .running(nil)
        let input = job.url
        guard FileManager.default.fileExists(atPath: input.path) else { job.status = .failed("The file is no longer there."); return }

        // Does this file fit the template? Video → audio extracts the sound; GIF → video works.
        let target = t.format.kind
        let srcKind = job.kind
        let isGIF = input.pathExtension.lowercased() == "gif"
        switch (srcKind, target) {
        case (.image, .image), (.audio, .audio), (.video, .audio), (.video, .video): break
        case (.image, .video) where isGIF: break
        case (.image?, _): job.status = .skipped("An image can’t become \(t.format.title)."); return
        case (.audio?, .video): job.status = .skipped("Audio can’t become a video."); return
        case (.audio?, .image), (.video?, .image): job.status = .skipped("Choose an audio or video template for this file."); return
        case (nil, .image): job.status = .skipped("Not an image."); return
        case (nil, _): break   // unknown type: let ffprobe decide
        default: break
        }

        let out = outputURL(for: input, format: t.format, folder: folder, reserved: reserved)
        reserved.insert(out.path)
        defer { reserved.remove(out.path) }
        // Written under a hidden temporary name, renamed when complete: a half-written file never
        // carries the final name.
        let part = out.deletingLastPathComponent()
            .appendingPathComponent(".\(out.deletingPathExtension().lastPathComponent).morphit-part.\(out.pathExtension)")
        try? FileManager.default.removeItem(at: part)

        do {
            if target == .image {
                if let i = ImageConvert.info(input) {
                    let (w, h) = ImageConvert.outputSize(width: i.width, height: i.height, t.image)
                    job.detail = (w, h) == (i.width, i.height) ? "\(i.width)×\(i.height)" : "\(i.width)×\(i.height) → \(w)×\(h)"
                }
                try await ImageConvert.convert(input, to: part, t, threads: max(1, cpu.threadsPerJob), qos: cpu.qos)
            } else {
                var info = try await Probe.run(input)
                await Probe.fillMissingBitrates(&info, input)
                if info.video == nil && info.audio.isEmpty { throw ToolError(message: "No audio or video in this file.") }
                job.detail = describe(info)
                let plan = target == .audio
                    ? try MediaPlan.audio(info, t, input: input, output: part, threads: cpu.threadsPerJob)
                    : try MediaPlan.video(info, t, input: input, output: part, threads: cpu.threadsPerJob)
                job.note = plan.notes.first
                let duration = plan.duration
                try await runFFmpeg(plan.args, qos: cpu.qos) { seconds in
                    guard duration > 0 else { return }
                    let f = min(1, seconds / duration)
                    Task { @MainActor in if case .running = job.status { job.status = .running(f) } }
                }
            }
            try Task.checkCancellation()
            let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0
            guard size > 0 else { throw ToolError(message: "The converted file came out empty.") }
            // The name may have been taken meanwhile (another app): pick again.
            let final = FileManager.default.fileExists(atPath: out.path)
                ? outputURL(for: input, format: t.format, folder: folder, reserved: reserved) : out
            try FileManager.default.moveItem(at: part, to: final)
            job.status = .done(final)

            // The original goes to the Trash only now: converted, written, renamed, and never the
            // same file as the result. Never deleted outright.
            if trash, final.standardizedFileURL.path != input.standardizedFileURL.path {
                do {
                    try FileManager.default.trashItem(at: input, resultingItemURL: nil)
                    job.trashed = true
                } catch {
                    job.note = "Converted, but the original couldn’t be moved to the Trash."
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: part)
            if Task.isCancelled || error is CancellationError {
                job.status = .cancelled
            } else {
                job.status = .failed(error.localizedDescription)
            }
        }
    }

    private func describe(_ i: MediaInfo) -> String {
        var parts: [String] = []
        if let v = i.video {
            let (w, h) = v.displaySize
            parts.append("\(w)×\(h)")
            parts.append(v.codec.uppercased())
        } else if let a = i.audio.first {
            parts.append(a.codec.replacingOccurrences(of: "pcm_", with: "PCM ").uppercased())
            if let b = i.audioBitrate(a), !MediaInfo.isLossless(a.codec) { parts.append("\(b / 1000) kbps") }
            if a.sampleRate > 0 { parts.append(String(format: "%g kHz", Double(a.sampleRate) / 1000)) }
            parts.append(a.channels == 1 ? "mono" : a.channels == 2 ? "stereo" : "\(a.channels) ch")
        }
        if i.duration > 0 { parts.append(timeString(i.duration)) }
        return parts.joined(separator: " · ")
    }
}

func timeString(_ t: Double) -> String {
    let s = Int(t.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
