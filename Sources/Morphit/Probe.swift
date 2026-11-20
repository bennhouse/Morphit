import Foundation

/// What ffprobe reports about a file, reduced to what the conversions need.
struct MediaInfo {
    struct Stream {
        var index: Int
        var type: String              // video, audio, subtitle, attachment, data
        var codec: String
        var width = 0, height = 0
        var fps: Double = 0
        var bitrate: Int?              // bits per second
        var sampleRate = 0
        var channels = 0
        var sampleFormat = ""
        var bitsPerSample = 0
        var pixelFormat = ""
        var rotation = 0               // degrees, from the display matrix
        var isCover = false            // attached picture (album art)

        /// Width and height as shown (after rotation).
        var displaySize: (Int, Int) { abs(rotation) % 180 == 90 ? (height, width) : (width, height) }
        var isTenBit: Bool { pixelFormat.contains("10") || pixelFormat.contains("12") || pixelFormat.hasPrefix("p010") }
    }

    var duration: Double = 0
    var formatBitrate: Int?
    var formatName = ""
    var streams: [Stream] = []

    var video: Stream? { streams.first { $0.type == "video" && !$0.isCover } }
    var audio: [Stream] { streams.filter { $0.type == "audio" } }
    var cover: Stream? { streams.first { $0.isCover } }
    var subtitles: [Stream] { streams.filter { $0.type == "subtitle" } }

    /// Bitrate of an audio stream: as declared, or (audio-only files) the whole file's.
    func audioBitrate(_ s: Stream) -> Int? {
        if let b = s.bitrate, b > 0 { return b }
        if video == nil, audio.count == 1, let b = formatBitrate { return b }
        return nil
    }

    /// Bitrate of the video stream: as declared, or the file's minus its audio.
    var videoBitrate: Int? {
        guard let v = video else { return nil }
        if let b = v.bitrate, b > 0 { return b }
        guard let total = formatBitrate else { return nil }
        let a = audio.compactMap { $0.bitrate }.reduce(0, +)
        return total - a > 0 ? total - a : nil
    }

    static let losslessAudio: Set<String> = ["flac", "alac", "wavpack", "ape", "tta", "mlp", "truehd", "dsd_lsbf", "dsd_msbf"]
    static func isLossless(_ codec: String) -> Bool { codec.hasPrefix("pcm_") || losslessAudio.contains(codec) }
}

enum Probe {
    static func run(_ url: URL) async throws -> MediaInfo {
        let r = try await runTool(Tools.ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path], qos: .userInitiated)
        guard r.status == 0, let root = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any] else {
            throw ToolError(message: r.stderr.contains("Invalid data") || r.stderr.isEmpty
                            ? "The file is damaged or isn’t a media file." : ToolError.from(stderr: r.stderr, status: r.status).message)
        }
        return parse(root)
    }

    static func parse(_ root: [String: Any]) -> MediaInfo {
        var info = MediaInfo()
        let f = root["format"] as? [String: Any] ?? [:]
        info.duration = num(f["duration"]) ?? 0
        info.formatBitrate = num(f["bit_rate"]).map { Int($0) }
        info.formatName = f["format_name"] as? String ?? ""
        for s in root["streams"] as? [[String: Any]] ?? [] {
            var st = MediaInfo.Stream(index: s["index"] as? Int ?? 0, type: s["codec_type"] as? String ?? "", codec: s["codec_name"] as? String ?? "")
            st.width = s["width"] as? Int ?? 0
            st.height = s["height"] as? Int ?? 0
            st.fps = rate(s["avg_frame_rate"] as? String) ?? rate(s["r_frame_rate"] as? String) ?? 0
            if st.fps > 1000 { st.fps = rate(s["r_frame_rate"] as? String) ?? 0 }
            let tags = s["tags"] as? [String: Any] ?? [:]
            // Matroska keeps the bitrate in a "BPS" tag.
            st.bitrate = num(s["bit_rate"]).map { Int($0) } ?? num(tags["BPS"]).map { Int($0) } ?? num(tags["BPS-eng"]).map { Int($0) }
            st.sampleRate = Int(num(s["sample_rate"]) ?? 0)
            st.channels = s["channels"] as? Int ?? 0
            st.sampleFormat = s["sample_fmt"] as? String ?? ""
            st.bitsPerSample = Int(num(s["bits_per_raw_sample"]) ?? 0)
            if st.bitsPerSample == 0 { st.bitsPerSample = s["bits_per_sample"] as? Int ?? 0 }
            st.pixelFormat = s["pix_fmt"] as? String ?? ""
            if let disp = s["disposition"] as? [String: Any], (disp["attached_pic"] as? Int) == 1 { st.isCover = true }
            for sd in s["side_data_list"] as? [[String: Any]] ?? [] {
                if let r = sd["rotation"] as? Int { st.rotation = r } else if let r = sd["rotation"] as? Double { st.rotation = Int(r) }
            }
            if st.rotation == 0, let r = num(tags["rotate"]) { st.rotation = Int(r) }
            info.streams.append(st)
        }
        return info
    }

    /// Fills in bitrates the container doesn't declare (WebM, some MKV and Ogg files), measured from
    /// the packets of the first two minutes. "Same as source" needs a real number.
    static func fillMissingBitrates(_ info: inout MediaInfo, _ url: URL) async {
        for i in info.streams.indices {
            let s = info.streams[i]
            let wanted = (s.type == "audio" && !MediaInfo.isLossless(s.codec) && info.audioBitrate(s) == nil)
                || (s.type == "video" && !s.isCover && info.videoBitrate == nil)
            guard wanted, s.bitrate == nil || s.bitrate == 0 else { continue }
            guard let r = try? await runTool(Tools.ffprobe, ["-v", "error", "-select_streams", "\(s.index)", "-read_intervals", "%+120",
                                                             "-show_entries", "packet=size,pts_time", "-of", "csv=p=0", url.path]),
                  r.status == 0 else { continue }
            var bytes = 0, first = Double.infinity, last = 0.0
            for line in String(decoding: r.stdout, as: UTF8.self).split(whereSeparator: \.isNewline) {
                let f = line.split(separator: ",")
                guard f.count >= 2, let t = Double(f[0]), let n = Int(f[1]) else { continue }
                bytes += n; first = min(first, t); last = max(last, t)
            }
            let span = last - first
            if span > 0.5 { info.streams[i].bitrate = Int(Double(bytes * 8) / span) }
        }
    }

    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func rate(_ s: String?) -> Double? {
        guard let s else { return nil }
        let p = s.split(separator: "/")
        guard p.count == 2, let a = Double(p[0]), let b = Double(p[1]), b > 0, a > 0 else { return nil }
        return a / b
    }
}
