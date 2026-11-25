import Foundation

/// Turns a template into ffmpeg arguments for one file. "Same as source" is never "leave it to
/// ffmpeg's default": the source's value is read with ffprobe and passed explicitly, adapted only
/// when the output format can't hold it (5.1 into MP3, 96 kHz into AAC, VP9 into MP4…).
struct MediaPlan {
    var args: [String] = []
    /// Seconds of output expected, for the progress bar (0 = unknown).
    var duration: Double = 0
    /// Human-readable notes on adaptations ("5.1 mixed down to stereo: MP3 has two channels").
    var notes: [String] = []

    // MARK: Audio output

    static func audio(_ info: MediaInfo, _ t: ConversionTemplate, input: URL, output: URL, threads: Int) throws -> MediaPlan {
        guard let src = info.audio.first else { throw ToolError(message: "This file has no sound to convert.") }
        var p = MediaPlan()
        p.duration = info.duration
        let a = t.audio
        p.args = ["-y", "-i", input.path, "-threads", "\(threads)", "-map", "0:\(src.index)"]

        // Album art: kept in the formats that can hold a picture.
        let coverOK = [.mp3, .m4a, .flac].contains(t.format) && a.keepCover
        if coverOK, let cover = info.cover, ["mjpeg", "png"].contains(cover.codec) {
            p.args += ["-map", "0:\(cover.index)", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
        } else {
            p.args += ["-vn"]
        }
        p.args += a.keepMetadata ? ["-map_metadata", "0"] : ["-map_metadata", "-1"]

        // Channels
        var channels = src.channels
        switch a.channels {
        case .mono: channels = 1
        case .stereo: channels = 2
        case .source:
            if t.format == .mp3 && channels > 2 { channels = 2; p.notes.append("Mixed down to stereo: MP3 holds two channels.") }
        }
        if channels != src.channels { p.args += ["-ac", "\(channels)"] }

        // Sample rate
        let allowed: [Int]
        switch t.format {
        case .mp3: allowed = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
        case .m4a where a.m4aCodec == .alac: allowed = []
        case .m4a, .aac: allowed = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
        case .opus: allowed = [8000, 12000, 16000, 24000, 48000]
        default: allowed = []
        }
        var rate = a.sampleRate ?? src.sampleRate
        if !allowed.isEmpty && !allowed.contains(rate) {
            let fitted = nearestRate(rate, allowed)
            if a.sampleRate == nil, t.format != .opus { p.notes.append("Sample rate \(rate) Hz lowered to \(fitted) Hz, the most \(t.format.title) holds.") }
            rate = fitted
        }
        // loudnorm resamples to 192 kHz internally: the rate is always given when normalising.
        if rate > 0 && (rate != src.sampleRate || t.format == .opus || a.normalize) { p.args += ["-ar", "\(rate)"] }

        // Bitrate for lossy formats: the source's, clamped to what the encoder accepts.
        let srcKbps = info.audioBitrate(src).map { Int((Double($0) / 1000).rounded()) }
        func kbps(max: Int, min: Int = 32) -> Int {
            if let b = a.bitrate { return Swift.min(Swift.max(b, min), max) }
            // A lossless source has no bitrate to match: the highest standard step.
            if MediaInfo.isLossless(src.codec) || srcKbps == nil { return Swift.min(320, max) }
            return Swift.min(Swift.max(srcKbps!, min), max)
        }
        if a.normalize { p.args += ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11"] }

        switch t.format {
        case .mp3:
            // MP3 has fixed steps: the next one up from the source's bitrate.
            let raw = kbps(max: 320)
            let b = a.bitrate ?? ([32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320].first { $0 >= raw } ?? 320)
            p.args += ["-c:a", "libmp3lame"]
            if a.bitrateMode == .variable {
                // LAME VBR presets by their typical bitrate (V0 ≈ 245 kbps … V6 ≈ 115 kbps).
                let q = b >= 240 ? 0 : b >= 210 ? 1 : b >= 180 ? 2 : b >= 160 ? 3 : b >= 145 ? 4 : b >= 125 ? 5 : 6
                p.args += ["-q:a", "\(q)"]
            } else {
                p.args += ["-b:a", "\(b)k"]
            }
            p.args += ["-id3v2_version", "3"]
        case .m4a where a.m4aCodec == .alac:
            p.args += ["-c:a", "alac"]
            let depth = a.bitDepth ?? sourceDepth(src)
            p.args += ["-sample_fmt", depth > 16 ? "s32p" : "s16p"]
        case .m4a, .aac:
            // Apple's AAC encoder (AudioToolbox), the best AAC available.
            let maxK = channels <= 1 ? 256 : channels == 2 ? 320 : 640
            p.args += ["-c:a", "aac_at", "-b:a", "\(kbps(max: maxK))k", "-aac_at_mode", a.bitrateMode == .variable ? "cvbr" : "cbr"]
            if t.format == .aac { p.args += ["-f", "adts"] }
        case .ogg:
            // Vorbis is variable by nature, and its average-bitrate mode refuses many combinations
            // (96 kHz, mono above 240 kbps): its quality scale, picked by the stereo-equivalent bitrate.
            let eq = kbps(max: 500, min: 48) * 2 / max(1, min(channels, 2))
            let q = eq >= 400 ? 10 : eq >= 300 ? 9 : eq >= 240 ? 8 : eq >= 210 ? 7 : eq >= 180 ? 6 : eq >= 150 ? 5 : eq >= 120 ? 4 : eq >= 100 ? 3 : 2
            p.args += ["-c:a", "libvorbis", "-q:a", "\(q)"]
        case .opus:
            let maxK = channels <= 1 ? 256 : channels == 2 ? 510 : 256 * channels
            p.args += ["-c:a", "libopus", "-b:a", "\(kbps(max: maxK, min: 16))k", "-vbr", a.bitrateMode == .variable ? "on" : "off"]
        case .wav:
            let depth = a.bitDepth ?? sourceDepth(src)
            p.args += ["-c:a", depth >= 32 ? "pcm_f32le" : depth == 24 ? "pcm_s24le" : "pcm_s16le"]
        case .flac:
            let depth = min(a.bitDepth ?? sourceDepth(src), 24)
            p.args += ["-c:a", "flac", "-compression_level", "\(a.flacLevel)", "-sample_fmt", depth > 16 ? "s32" : "s16"]
            if depth > 16 { p.args += ["-bits_per_raw_sample", "24"] }
        default:
            throw ToolError(message: "\(t.format.title) isn’t an audio format.")
        }
        if [.m4a].contains(t.format) { p.args += ["-movflags", "+faststart"] }
        p.args += [output.path]
        return p
    }

    /// Bit depth of the source: its integer depth, 32 for float, 16 for lossy sources (MP3, AAC…
    /// have no bit depth; they decode to float).
    static func sourceDepth(_ s: MediaInfo.Stream) -> Int {
        if !MediaInfo.isLossless(s.codec) { return 16 }
        if s.sampleFormat.hasPrefix("flt") || s.sampleFormat.hasPrefix("dbl") { return 32 }
        if s.bitsPerSample > 16 { return s.bitsPerSample >= 32 && s.codec.hasPrefix("pcm_f") ? 32 : 24 }
        if s.sampleFormat.hasPrefix("s32") { return 24 }
        return 16
    }

    /// The closest allowed rate, staying in the same family (44.1 kHz or 48 kHz) when possible.
    static func nearestRate(_ r: Int, _ allowed: [Int]) -> Int {
        if r > allowed.max()! {
            let family44 = r % 11025 == 0
            if family44, allowed.contains(44100) { return 44100 }
            return allowed.max()!
        }
        return allowed.min { abs($0 - r) < abs($1 - r) }!
    }

    // MARK: Video output

    static func video(_ info: MediaInfo, _ t: ConversionTemplate, input: URL, output: URL, threads: Int) throws -> MediaPlan {
        guard let v = info.video else { throw ToolError(message: "This file has no video to convert.") }
        var p = MediaPlan()
        p.duration = info.duration
        let s = t.video
        let fmt = t.format
        p.args = ["-y", "-i", input.path, "-threads", "\(threads)"]

        // Filters: frame rate, then size (fits the short side, never enlarges).
        var filters: [String] = []
        if let fps = s.frameRate, abs(fps - v.fps) > 0.01 {
            filters.append("fps=\(fpsString(fps))")
        }
        let (w, h) = v.displaySize
        var outW = w, outH = h
        if let target = s.resolution, min(w, h) > target {
            let scale = Double(target) / Double(min(w, h))
            outW = even(Double(w) * scale); outH = even(Double(h) * scale)
            filters.append("scale=\(outW):\(outH):flags=lanczos")
        }

        if fmt == .gif {
            // Two passes in one graph: a palette made for this clip, then dithered with it.
            var chain = filters
            if s.frameRate == nil && v.fps > 50 { chain.insert("fps=50", at: 0); p.notes.append("GIF plays at most 50 frames per second.") }
            let pre = chain.isEmpty ? "" : chain.joined(separator: ",") + ","
            p.args += ["-filter_complex",
                       "[0:\(v.index)]\(pre)split[a][b];[a]palettegen=stats_mode=diff[pal];[b][pal]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle[gif]",
                       "-map", "[gif]",
                       "-loop", s.gifLoop ? "0" : "-1", "-f", "gif", output.path]
            return p
        }

        // Video codec: the source's when the container takes it and nothing forces a re-encode.
        let srcCodec = VideoCodec.allCases.first { $0.probeName == v.codec }
        let containerTakes = fmt == .mkv || (srcCodec.map { fmt.videoCodecs.contains($0) } ?? false)
            || (fmt == .mov && ["mjpeg", "mpeg4"].contains(v.codec)) || (fmt == .mp4 && v.codec == "mpeg4")
        let mustEncode = !filters.isEmpty || s.quality != .source || s.crf != nil
        let codec: VideoCodec?   // nil = copy
        if let chosen = s.codec, fmt.videoCodecs.contains(chosen) {
            codec = (chosen.probeName == v.codec && !mustEncode) ? nil : chosen
        } else if containerTakes && !mustEncode {
            codec = nil
        } else if let src = srcCodec, fmt.videoCodecs.contains(src) {
            codec = src
        } else {
            codec = fmt.videoCodecs.first
            if !containerTakes { p.notes.append("\(v.codec.uppercased()) can’t go in \(fmt.title): converted to \(fmt.videoCodecs.first!.title).") }
        }

        p.args += ["-map", "0:\(v.index)"]
        if let codec {
            if !filters.isEmpty { p.args += ["-vf", filters.joined(separator: ",")] }
            p.args += encoderArgs(codec, info: info, v: v, s: s, outPixels: outW * outH, threads: threads)
        } else {
            p.args += ["-c:v", "copy"]
        }
        if codec == .hevc || (codec == nil && v.codec == "hevc"), fmt == .mp4 || fmt == .mov {
            p.args += ["-tag:v", "hvc1"]   // QuickTime and iOS play HEVC only with this tag
        }

        // Audio tracks
        let tracks = s.allAudioTracks ? info.audio : Array(info.audio.prefix(1))
        if s.audio != .remove, !tracks.isEmpty {
            let copyable: Set<String>
            switch fmt {
            case .mp4: copyable = ["aac", "mp3", "alac", "ac3", "eac3"]
            case .mov: copyable = ["aac", "alac", "mp3", "ac3", "pcm_s16le", "pcm_s24le", "pcm_s16be", "pcm_s24be"]
            case .webm: copyable = ["opus", "vorbis"]
            default: copyable = []   // mkv: everything
            }
            for (i, a) in tracks.enumerated() {
                p.args += ["-map", "0:\(a.index)"]
                let canCopy = fmt == .mkv || copyable.contains(a.codec)
                if s.audio == .source && canCopy && s.audioBitrate == nil {
                    p.args += ["-c:a:\(i)", "copy"]
                } else {
                    let srcK = info.audioBitrate(a).map { Int((Double($0) / 1000).rounded()) }
                    let lossless = MediaInfo.isLossless(a.codec)
                    var k = s.audioBitrate ?? (lossless ? 320 : srcK ?? 192)
                    let ch = a.channels
                    if fmt == .webm {
                        k = min(max(k, 32), ch <= 2 ? 510 : 256 * ch)
                        p.args += ["-c:a:\(i)", "libopus", "-b:a:\(i)", "\(k)k", "-ar:a:\(i)", "48000"]
                    } else {
                        k = min(max(k, 32), ch <= 1 ? 256 : ch == 2 ? 320 : 640)
                        p.args += ["-c:a:\(i)", "aac_at", "-b:a:\(i)", "\(k)k"]
                        if a.sampleRate > 48000 { p.args += ["-ar:a:\(i)", "48000"] }
                    }
                }
            }
        } else {
            p.args += ["-an"]
        }

        // Subtitles: copied in MKV; text subtitles become mov_text in MP4/MOV; WebM drops them.
        if s.keepSubtitles {
            let text: Set<String> = ["subrip", "ass", "ssa", "mov_text", "webvtt", "text"]
            for (i, sub) in info.subtitles.enumerated() {
                switch fmt {
                case .mkv:
                    p.args += ["-map", "0:\(sub.index)", "-c:s:\(i)", "copy"]
                case .mp4, .mov where text.contains(sub.codec):
                    p.args += ["-map", "0:\(sub.index)", "-c:s:\(i)", "mov_text"]
                default: break
                }
            }
            if fmt == .mkv { p.args += ["-map", "0:t?", "-c:t", "copy"] }   // fonts for ASS subtitles
        }

        p.args += s.keepMetadata ? ["-map_metadata", "0", "-map_chapters", "0"] : ["-map_metadata", "-1", "-map_chapters", "-1"]
        if fmt == .mp4 || fmt == .mov { p.args += ["-movflags", "+faststart"] }
        p.args += [output.path]
        return p
    }

    /// Encoder arguments. Quality "Same as source" means the source's bitrate (scaled with the
    /// picture size); the presets use constant quality (CRF, or -q:v on the hardware encoder).
    static func encoderArgs(_ codec: VideoCodec, info: MediaInfo, v: MediaInfo.Stream, s: VideoSettings, outPixels: Int, threads: Int) -> [String] {
        let hardware: Bool
        switch s.encoder {
        case .hardware: hardware = codec == .h264 || codec == .hevc || codec == .prores
        case .software: hardware = codec == .prores   // ProRes has only the Apple encoder here
        // A CRF value only means something to the software encoders.
        case .auto: hardware = ((codec == .h264 || codec == .hevc) && s.crf == nil) || codec == .prores
        }
        let tenBit = v.isTenBit && codec != .h264
        // Target bitrate for "Same as source": the source's, scaled by picture area^0.75.
        var target: Int? = nil
        if s.quality == .source && s.crf == nil, let b = info.videoBitrate {
            let srcPixels = Double(max(1, v.width * v.height))
            target = Int(Double(b) * pow(Double(outPixels) / srcPixels, 0.75))
        }
        // Custom bitrate: as chosen. With the resolution "same as source" it was chosen for 1080p,
        // so it is scaled to the real picture size (by area^0.75, like the source bitrate above).
        if s.quality == .custom, s.crf == nil, let k = s.bitrate {
            var bits = Double(k) * 1000
            if s.resolution == nil { bits *= pow(Double(outPixels) / BitrateRange.referencePixels, 0.75) }
            target = Int(bits)
        }
        let preset: (h264: Int, hevc: Int, av1: Int, vp9: Int, hw: Int) = {
            switch s.quality {
            case .source, .high, .custom: return (18, 20, 26, 28, 70)
            case .medium: return (23, 25, 33, 34, 58)
            case .low: return (28, 30, 40, 40, 45)
            }
        }()
        var a: [String] = []
        switch codec {
        case .prores:
            // Apple's encoder; Macs without the ProRes engine use its software path (-allow_sw).
            a = ["-c:v", "prores_videotoolbox", "-allow_sw", "1", "-profile:v", "standard", "-pix_fmt", "p210le"]
            return a
        case .h264:
            a = hardware ? ["-c:v", "h264_videotoolbox", "-profile:v", "high"] : ["-c:v", "libx264", "-preset", x26xPreset(s.speed)]
            a += ["-pix_fmt", "yuv420p"]
        case .hevc:
            a = hardware ? ["-c:v", "hevc_videotoolbox"] : ["-c:v", "libx265", "-preset", x26xPreset(s.speed), "-x265-params", "log-level=error"]
            a += ["-pix_fmt", tenBit ? (hardware ? "p010le" : "yuv420p10le") : (hardware ? "nv12" : "yuv420p")]
            if tenBit && hardware { a += ["-profile:v", "main10"] }
        case .av1:
            a = ["-c:v", "libsvtav1", "-preset", s.speed == .fast ? "10" : s.speed == .medium ? "8" : "5",
                 "-pix_fmt", tenBit ? "yuv420p10le" : "yuv420p"]
        case .vp9:
            a = ["-c:v", "libvpx-vp9", "-row-mt", "1", "-deadline", "good", "-cpu-used", s.speed == .fast ? "6" : s.speed == .medium ? "4" : "2",
                 "-pix_fmt", "yuv420p"]
        }
        if let target {
            a += ["-b:v", "\(target)"]
            if codec == .h264 || codec == .hevc, !hardware { a += ["-maxrate", "\(target * 3 / 2)", "-bufsize", "\(target * 2)"] }
        } else if hardware {
            a += ["-q:v", "\(preset.hw)"]
        } else {
            let crf: Int
            switch codec {
            case .h264: crf = s.crf ?? preset.h264
            case .hevc: crf = s.crf ?? preset.hevc
            case .av1: crf = s.crf ?? preset.av1
            default: crf = s.crf ?? preset.vp9
            }
            a += ["-crf", "\(crf)"]
            if codec == .vp9 { a += ["-b:v", "0"] }
        }
        return a
    }

    static func x26xPreset(_ s: EncoderSpeed) -> String {
        switch s {
        case .fast: "veryfast"
        case .medium: "medium"
        case .slow: "slow"
        }
    }

    static func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }

    static func fpsString(_ f: Double) -> String {
        switch f {
        case 23.976: "24000/1001"
        case 29.97: "30000/1001"
        case 59.94: "60000/1001"
        default: formatNumber(f)
        }
    }
}
