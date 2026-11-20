import Foundation

/// The conversion engine inside the app (Contents/Resources/bin), copied there by build-app.sh:
/// ffmpeg and ffprobe, static arm64 builds. Images to JPEG, PNG, HEIC, HEIF, TIFF and BMP are written
/// by macOS itself (ImageIO).
enum Tools {
    static var bundled: URL {
        if let dir = ProcessInfo.processInfo.environment["MORPHIT_TOOLS"] { return URL(fileURLWithPath: dir) }
        return Bundle.main.resourceURL!.appendingPathComponent("bin")
    }
    static var ffmpeg: URL { bundled.appendingPathComponent("ffmpeg") }
    static var ffprobe: URL { bundled.appendingPathComponent("ffprobe") }

    static var missing: [String] {
        [("ffmpeg", ffmpeg), ("ffprobe", ffprobe)]
            .filter { !FileManager.default.isExecutableFile(atPath: $0.1.path) }.map(\.0)
    }

    /// An app started from Finder has a bare environment: UTF-8 for file names with accents.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["SVT_LOG"] = "1"   // SVT-AV1: errors only
        env["PATH"] = bundled.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }
}

struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    /// The useful part of ffmpeg's error output: the last line that says what went wrong, without
    /// the follow-up noise ("Terminating thread…", "Nothing was written…") and "[x @ 0x…]" prefixes.
    static func from(stderr: String, status: Int32) -> ToolError {
        let noise = ["Terminating thread", "Task finished", "Nothing was written", "Error sending frames", "Conversion failed",
                     "Could not open encoder before EOF", "Error opening output file", "Error opening output files", "frame=", "size="]
        var lines = stderr.split(whereSeparator: \.isNewline).map { l -> String in
            var line = String(l).trimmingCharacters(in: .whitespaces)
            while let r = line.range(of: #"^\[[^\]]*\] *"#, options: .regularExpression) { line.removeSubrange(r) }
            return line
        }.filter { !$0.isEmpty }
        let all = lines
        lines = lines.filter { l in !noise.contains { l.contains($0) } }
        guard var line = lines.last ?? all.last else { return ToolError(message: "ffmpeg stopped with code \(status).") }
        if line.contains("Invalid data found when processing input") { line = "The file is damaged or isn’t a media file ffmpeg can read." }
        if line.contains("Permission denied") || line.contains("Operation not permitted") {
            line = "macOS didn’t allow access to the folder. Allow Morphit in System Settings › Privacy & Security › Files and Folders."
        }
        return ToolError(message: line)
    }
}

/// Runs a tool to completion and collects its output.
func runTool(_ exe: URL, _ args: [String], qos: QualityOfService = .userInitiated) async throws -> (status: Int32, stdout: Data, stderr: String) {
    let p = Process()
    p.executableURL = exe
    p.arguments = args
    p.environment = Tools.environment
    p.qualityOfService = qos
    p.standardInput = FileHandle.nullDevice
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { cont in
            // waitUntilExit() on a background thread can miss the exit and wait forever: the
            // termination handler is reliable.
            let exited = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in exited.signal() }
            do { try p.run() } catch { cont.resume(throwing: error); return }
            // Both pipes on their own threads, so a large output can't fill a pipe and stall the tool.
            DispatchQueue.global().async {
                let group = DispatchGroup()
                var o = Data(), e = Data()
                group.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.wait()
                exited.wait()
                cont.resume(returning: (p.terminationStatus, o, String(decoding: e, as: UTF8.self)))
            }
        }
    } onCancel: {
        if p.isRunning { p.terminate() }
    }
}

/// Runs ffmpeg with `-progress pipe:1` and reports the position reached (seconds) as it goes.
func runFFmpeg(_ args: [String], qos: QualityOfService, progress: @escaping @Sendable (Double) -> Void) async throws {
    let p = Process()
    p.executableURL = Tools.ffmpeg
    p.arguments = ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error", "-progress", "pipe:1"] + args
    p.environment = Tools.environment
    p.qualityOfService = qos
    p.standardInput = FileHandle.nullDevice
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    let status: (Int32, String) = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { cont in
            // waitUntilExit() on a background thread can miss the exit and wait forever: the
            // termination handler is reliable.
            let exited = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in exited.signal() }
            do { try p.run() } catch { cont.resume(throwing: error); return }
            DispatchQueue.global().async {
                let group = DispatchGroup()
                var e = Data()
                group.enter()
                DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                // Progress blocks are "key=value" lines; out_time_us is the position in the output.
                var pending = Data()
                let h = out.fileHandleForReading
                while true {
                    let chunk = h.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let nl = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                        pending.removeSubrange(pending.startIndex...nl)
                        if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)), us >= 0 {
                            progress(us / 1_000_000)
                        }
                    }
                }
                group.wait()
                exited.wait()
                cont.resume(returning: (p.terminationStatus, String(decoding: e, as: UTF8.self)))
            }
        }
    } onCancel: {
        if p.isRunning { p.terminate() }
    }
    try Task.checkCancellation()
    if status.0 != 0 { throw ToolError.from(stderr: status.1, status: status.0) }
}
