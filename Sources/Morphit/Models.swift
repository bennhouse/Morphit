import Foundation
import UniformTypeIdentifiers

// Everything a conversion can be told to do. Every parameter is optional or has a "source" case:
// nil / .source means "Same as source", the default for every parameter. Only what the user
// changes on purpose is different.

enum MediaKind: String, Codable, CaseIterable, Identifiable {
    case audio, video, image
    var id: String { rawValue }
    var title: String {
        switch self {
        case .audio: "Audio"
        case .video: "Video"
        case .image: "Image"
        }
    }
    var symbol: String {
        switch self {
        case .audio: "waveform"
        case .video: "film"
        case .image: "photo"
        }
    }
}

enum OutputFormat: String, Codable, CaseIterable, Identifiable {
    case mp3, m4a, aac, wav, flac, ogg, opus
    case mp4, mkv, mov, webm, gif
    case jpg, png, heic, heif, webp, avif, tiff, bmp

    var id: String { rawValue }

    var kind: MediaKind {
        switch self {
        case .mp3, .m4a, .aac, .wav, .flac, .ogg, .opus: .audio
        case .mp4, .mkv, .mov, .webm, .gif: .video
        case .jpg, .png, .heic, .heif, .webp, .avif, .tiff, .bmp: .image
        }
    }

    var fileExtension: String {
        switch self {
        case .tiff: "tiff"
        default: rawValue
        }
    }

    var title: String {
        switch self {
        case .mp3: "MP3"
        case .m4a: "M4A"
        case .aac: "AAC"
        case .wav: "WAV"
        case .flac: "FLAC"
        case .ogg: "OGG Vorbis"
        case .opus: "Opus"
        case .mp4: "MP4"
        case .mkv: "MKV"
        case .mov: "MOV"
        case .webm: "WebM"
        case .gif: "GIF"
        case .jpg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .heif: "HEIF"
        case .webp: "WebP"
        case .avif: "AVIF"
        case .tiff: "TIFF"
        case .bmp: "BMP"
        }
    }

    /// One line under the format in menus.
    var detail: String {
        switch self {
        case .mp3: "MPEG audio, plays everywhere"
        case .m4a: "AAC or Apple Lossless in an MP4 file"
        case .aac: "AAC stream (.aac)"
        case .wav: "Uncompressed PCM"
        case .flac: "Lossless, compressed"
        case .ogg: "Vorbis in Ogg"
        case .opus: "Opus in Ogg, efficient at low bitrates"
        case .mp4: "H.264, HEVC or AV1 with AAC"
        case .mkv: "Matroska, keeps every track"
        case .mov: "QuickTime: H.264, HEVC or ProRes"
        case .webm: "VP9 or AV1 with Opus, for the web"
        case .gif: "Animated GIF, no sound"
        case .jpg: "Photos, plays everywhere"
        case .png: "Lossless, with transparency"
        case .heic: "Apple's photo format, half the size of JPEG"
        case .heif: "HEIF image (HEVC), .heif extension"
        case .webp: "Web images, with transparency"
        case .avif: "AV1 image, very small files"
        case .tiff: "Lossless, for print and archives"
        case .bmp: "Uncompressed bitmap"
        }
    }

    var isLossyAudio: Bool { [.mp3, .m4a, .aac, .ogg, .opus].contains(self) }
    var isLossyImage: Bool { [.jpg, .heic, .heif, .webp, .avif].contains(self) }
    /// Image formats macOS can't write: done by ffmpeg, without metadata.
    var imageViaFFmpeg: Bool { self == .webp || self == .avif }

    /// Video codecs the user can choose for this container (the first is the default when the
    /// source codec can't be kept).
    var videoCodecs: [VideoCodec] {
        switch self {
        case .mp4: [.h264, .hevc, .av1]
        case .mkv: [.h264, .hevc, .av1, .vp9]
        case .mov: [.h264, .hevc, .prores]
        case .webm: [.vp9, .av1]
        default: []
        }
    }

    static func formats(_ kind: MediaKind) -> [OutputFormat] { allCases.filter { $0.kind == kind } }
}

// MARK: - Audio

enum ChannelMode: String, Codable, CaseIterable, Identifiable {
    case source, mono, stereo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .source: "Same as source"
        case .mono: "Mono"
        case .stereo: "Stereo"
        }
    }
}

enum BitrateMode: String, Codable, CaseIterable, Identifiable {
    case constant, variable
    var id: String { rawValue }
    var title: String { self == .constant ? "Constant (CBR)" : "Variable (VBR)" }
}

enum M4ACodec: String, Codable, CaseIterable, Identifiable {
    case aac, alac
    var id: String { rawValue }
    var title: String { self == .aac ? "AAC" : "Apple Lossless (ALAC)" }
}

struct AudioSettings: Codable, Equatable {
    var bitrate: Int?            // kbps
    var sampleRate: Int?         // Hz
    var channels: ChannelMode = .source
    // Advanced
    var bitrateMode: BitrateMode = .constant
    var bitDepth: Int?           // WAV, FLAC, ALAC: 16, 24, 32 (WAV: float)
    var flacLevel: Int = 5
    var m4aCodec: M4ACodec = .aac
    var keepMetadata = true
    var keepCover = true
    var normalize = false

    static let bitrates = [64, 96, 128, 160, 192, 224, 256, 320]
    static let opusBitrates = [32, 48, 64, 96, 128, 160, 192, 256, 320, 450, 510]
    static let sampleRates = [22050, 32000, 44100, 48000, 88200, 96000]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bitrate = c.value(.bitrate, nil)
        sampleRate = c.value(.sampleRate, nil)
        channels = c.value(.channels, .source)
        bitrateMode = c.value(.bitrateMode, .constant)
        bitDepth = c.value(.bitDepth, nil)
        flacLevel = c.value(.flacLevel, 5)
        m4aCodec = c.value(.m4aCodec, .aac)
        keepMetadata = c.value(.keepMetadata, true)
        keepCover = c.value(.keepCover, true)
        normalize = c.value(.normalize, false)
    }
}

// MARK: - Video

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case h264, hevc, av1, vp9, prores
    var id: String { rawValue }
    var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC (H.265)"
        case .av1: "AV1"
        case .vp9: "VP9"
        case .prores: "ProRes 422"
        }
    }
    /// ffprobe's codec_name for this codec.
    var probeName: String { self == .h264 ? "h264" : rawValue }
}

enum VideoQuality: String, Codable, CaseIterable, Identifiable {
    case source, high, medium, low, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .source: "Same as source"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Small file"
        case .custom: "Custom bitrate"
        }
    }
}

/// Sensible video bitrates for a resolution, frame rate and codec: from a small file to very high
/// quality, in bits per pixel (H.264 values; newer codecs need less for the same quality).
struct BitrateRange {
    let min: Int, small: Int, medium: Int, high: Int, max: Int   // kbps
    let shortSide: Int, fps: Double, codec: VideoCodec
    /// Resolution or frame rate "same as source": the range is shown for 1080p / 30 fps.
    let assumed: Bool

    static let referencePixels = 1920.0 * 1080

    init(codec: VideoCodec?, format: OutputFormat, resolution: Int?, frameRate: Double?) {
        let c = codec ?? format.videoCodecs.first ?? .h264
        self.codec = c
        shortSide = resolution ?? 1080
        fps = frameRate ?? 30
        assumed = resolution == nil || frameRate == nil
        let pixels = Double(shortSide) * Double(shortSide) * 16 / 9
        // More frames need more bits, but less than in proportion (frames are alike).
        let effectiveFPS = 30 * pow(fps / 30, 0.75)
        let efficiency: Double = switch c {
        case .h264, .prores: 1
        case .hevc: 0.6
        case .av1: 0.5
        case .vp9: 0.65
        }
        func kbps(_ bpp: Double) -> Int { BitrateRange.nice(pixels * effectiveFPS * bpp * efficiency / 1000) }
        min = kbps(0.025); small = kbps(0.05); medium = kbps(0.09); high = kbps(0.14); max = kbps(0.3)
    }

    /// Rounded to a step that suits the size.
    static func nice(_ k: Double) -> Int {
        let step: Double = k < 1000 ? 50 : k < 10000 ? 100 : 500
        return Swift.max(Int(step), Int((k / step).rounded() * step))
    }

    func label(_ kbps: Int) -> String {
        if kbps < small { return "Very small file" }
        if kbps < (small + medium) / 2 { return "Small file" }
        if kbps < (medium + high) / 2 { return "Medium quality" }
        if kbps < (high + max) / 2 { return "High quality" }
        return "Very high quality"
    }
}

func formatKbps(_ k: Int) -> String {
    k >= 1000 ? String(format: "%g Mbps", (Double(k) / 100).rounded() / 10) : "\(k) kbps"
}

enum EncoderChoice: String, Codable, CaseIterable, Identifiable {
    case auto, hardware, software
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Automatic"
        case .hardware: "Hardware (fast)"
        case .software: "Software (smallest files)"
        }
    }
}

enum EncoderSpeed: String, Codable, CaseIterable, Identifiable {
    case fast, medium, slow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: "Fast"
        case .medium: "Balanced"
        case .slow: "Slow (smaller)"
        }
    }
}

enum AudioTrackMode: String, Codable, CaseIterable, Identifiable {
    case source, reencode, remove
    var id: String { rawValue }
    var title: String {
        switch self {
        case .source: "Same as source"
        case .reencode: "Convert"
        case .remove: "Remove"
        }
    }
}

struct VideoSettings: Codable, Equatable {
    var codec: VideoCodec?        // nil: keep the source codec when the container allows it
    var quality: VideoQuality = .source
    var resolution: Int?          // short side in pixels (1080 = 1080p), never enlarged
    var frameRate: Double?
    var audio: AudioTrackMode = .source
    var audioBitrate: Int?
    // Advanced
    var encoder: EncoderChoice = .auto
    var speed: EncoderSpeed = .medium
    var crf: Int?                 // overrides the quality preset (software encoders)
    var bitrate: Int?             // kbps, with quality .custom
    var allAudioTracks = true
    var keepSubtitles = true
    var keepMetadata = true
    var gifLoop = true

    static let resolutions = [2160, 1440, 1080, 720, 540, 480, 360, 240]
    static let frameRates: [Double] = [10, 12, 15, 23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        codec = c.value(.codec, nil)
        quality = c.value(.quality, .source)
        resolution = c.value(.resolution, nil)
        frameRate = c.value(.frameRate, nil)
        audio = c.value(.audio, .source)
        audioBitrate = c.value(.audioBitrate, nil)
        encoder = c.value(.encoder, .auto)
        speed = c.value(.speed, .medium)
        crf = c.value(.crf, nil)
        bitrate = c.value(.bitrate, nil)
        allAudioTracks = c.value(.allAudioTracks, true)
        keepSubtitles = c.value(.keepSubtitles, true)
        keepMetadata = c.value(.keepMetadata, true)
        gifLoop = c.value(.gifLoop, true)
    }
}

// MARK: - Image

enum ResizeMode: String, Codable, CaseIterable, Identifiable {
    case none, longSide, shortSide, megapixels, percent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Same as source"
        case .longSide: "Long side"
        case .shortSide: "Short side"
        case .megapixels: "Megapixels"
        case .percent: "Percentage"
        }
    }
    var unit: String {
        switch self {
        case .none: ""
        case .longSide, .shortSide: "px"
        case .megapixels: "MP"
        case .percent: "%"
        }
    }
    var defaultValue: Double {
        switch self {
        case .none: 0
        case .longSide: 2048
        case .shortSide: 1080
        case .megapixels: 12
        case .percent: 50
        }
    }
}

enum MetadataMode: String, Codable, CaseIterable, Identifiable {
    case keep, removeLocation, removeAll
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keep: "Same as source"
        case .removeLocation: "Remove location"
        case .removeAll: "Remove all"
        }
    }
}

enum ColorMode: String, Codable, CaseIterable, Identifiable {
    case source, sRGB
    var id: String { rawValue }
    var title: String { self == .source ? "Same as source" : "Convert to sRGB" }
}

enum TIFFCompression: String, Codable, CaseIterable, Identifiable {
    case none, lzw
    var id: String { rawValue }
    var title: String { self == .none ? "None" : "LZW" }
    var tag: Int { self == .none ? 1 : 5 }
}

struct ImageSettings: Codable, Equatable {
    var quality: Int?             // 1...100; nil = same as source (estimated)
    var resize: ResizeMode = .none
    var resizeValue: Double = 0
    var metadata: MetadataMode = .keep
    // Advanced
    var enlarge = false           // allow making images bigger than the source
    var color: ColorMode = .source
    var tiffCompression: TIFFCompression?
    var lossless = false          // WebP

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quality = c.value(.quality, nil)
        resize = c.value(.resize, .none)
        resizeValue = c.value(.resizeValue, 0)
        metadata = c.value(.metadata, .keep)
        enlarge = c.value(.enlarge, false)
        color = c.value(.color, .source)
        tiffCompression = c.value(.tiffCompression, nil)
        lossless = c.value(.lossless, false)
    }
}

// MARK: - Template

/// A "conversion template": a name, an output format and its parameters. The audio, video and
/// image parameters are kept side by side, so switching the format back and forth loses nothing;
/// only those of the format's kind are used.
struct ConversionTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var format: OutputFormat
    var audio = AudioSettings()
    var video = VideoSettings()
    var image = ImageSettings()

    init(name: String, format: OutputFormat, audio: AudioSettings = .init(), video: VideoSettings = .init(), image: ImageSettings = .init()) {
        self.name = name; self.format = format; self.audio = audio; self.video = video; self.image = image
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        name = c.value(.name, "Template")
        let rawFormat: String = c.value(.format, "mp3")
        format = OutputFormat(rawValue: rawFormat) ?? (rawFormat == "hevc" ? .mp4 : .mp3)
        audio = c.value(.audio, AudioSettings())
        video = c.value(.video, VideoSettings())
        image = c.value(.image, ImageSettings())
        // The old "HEVC (MP4)" format is MP4 with the HEVC codec.
        if rawFormat == "hevc", video.codec == nil { video.codec = .hevc }
    }

    /// Same parameters (ignores id and name).
    func sameSettings(as o: ConversionTemplate) -> Bool {
        format == o.format && audio == o.audio && video == o.video && image == o.image
    }

    /// One line for the main window: "MP3 · 320 kbps · Stereo".
    var summary: String {
        var parts = [format.title]
        switch format.kind {
        case .audio:
            if format == .m4a && audio.m4aCodec == .alac { parts.append("Apple Lossless") }
            if format.isLossyAudio && !(format == .m4a && audio.m4aCodec == .alac) {
                parts.append(audio.bitrate.map { "\($0) kbps" } ?? "bitrate as source")
            }
            if let r = audio.sampleRate { parts.append(String(format: "%g kHz", Double(r) / 1000)) }
            if audio.channels != .source { parts.append(audio.channels.title) }
        case .video:
            if format != .gif { parts.append(video.codec?.title ?? "codec as source") }
            if video.quality == .custom, let b = video.bitrate { parts.append(formatKbps(b)) }
            else if video.quality != .source { parts.append("\(video.quality.title) quality") }
            parts.append(video.resolution.map { "\($0)p" } ?? "size as source")
            if let f = video.frameRate { parts.append(String(format: "%g fps", f)) }
            if video.audio == .remove && format != .gif { parts.append("no audio") }
        case .image:
            if format.isLossyImage { parts.append(image.quality.map { "quality \($0)" } ?? "quality as source") }
            if image.resize != .none {
                parts.append("\(image.resize.title.lowercased()) \(formatNumber(image.resizeValue)) \(image.resize.unit)")
            } else {
                parts.append("size as source")
            }
            if image.metadata != .keep { parts.append(image.metadata.title.lowercased()) }
        }
        return parts.joined(separator: " · ")
    }

    static var builtIn: [ConversionTemplate] {
        var m4a = AudioSettings(); m4a.bitrate = 256; m4a.channels = .stereo
        return [
            .init(name: "MP3", format: .mp3),
            .init(name: "M4A", format: .m4a, audio: m4a),
            .init(name: "WAV", format: .wav),
            .init(name: "FLAC", format: .flac),
            .init(name: "Opus", format: .opus),
            .init(name: "MP4", format: .mp4),
            .init(name: "MKV", format: .mkv),
            .init(name: "MOV", format: .mov),
            .init(name: "WebM", format: .webm),
            .init(name: "GIF", format: .gif),
            .init(name: "JPEG", format: .jpg),
            .init(name: "PNG", format: .png),
            .init(name: "HEIC", format: .heic),
            .init(name: "WebP", format: .webp),
            .init(name: "AVIF", format: .avif),
            .init(name: "TIFF", format: .tiff),
        ]
    }
}

func formatNumber(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
}

extension KeyedDecodingContainer {
    /// The stored value, or `fallback` when the key is missing or unreadable (older template files).
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

// MARK: - App-wide options

enum CPULevel: String, Codable, CaseIterable, Identifiable {
    case low, balanced, maximum
    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: "Low"
        case .balanced: "Balanced"
        case .maximum: "Maximum"
        }
    }
    var help: String {
        switch self {
        case .low: "One file at a time on two cores, at low priority: the Mac stays responsive."
        case .balanced: "A few files at a time, on half the cores."
        case .maximum: "As many files at a time as there are performance cores, on every core."
        }
    }

    static var cores: Int { ProcessInfo.processInfo.activeProcessorCount }
    static var performanceCores: Int {
        var n: Int32 = 0; var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &n, &size, nil, 0) == 0, n > 0 { return Int(n) }
        return max(1, cores / 2)
    }

    /// Files converted at the same time.
    var parallelJobs: Int {
        switch self {
        case .low: 1
        case .balanced: max(1, Self.performanceCores / 2)
        case .maximum: max(2, Self.performanceCores)
        }
    }
    /// ffmpeg -threads for each file (0 = ffmpeg decides).
    var threadsPerJob: Int {
        switch self {
        case .low: 2
        case .balanced: max(2, Self.cores / 2 / parallelJobs)
        case .maximum: 0
        }
    }
    var qos: QualityOfService {
        switch self {
        case .low: .utility
        case .balanced: .userInitiated
        case .maximum: .userInitiated
        }
    }
}

enum Prefs {
    static var cpu: CPULevel {
        get { CPULevel(rawValue: UserDefaults.standard.string(forKey: "cpuLevel") ?? "") ?? .balanced }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "cpuLevel") }
    }
    /// nil: next to each original.
    static var outputFolder: URL? {
        get { UserDefaults.standard.string(forKey: "outputFolder").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path ?? "", forKey: "outputFolder") }
    }
    /// Off by default. Only after a successful conversion, and only to the Trash.
    static var trashOriginals: Bool {
        get { UserDefaults.standard.bool(forKey: "trashOriginals") }
        set { UserDefaults.standard.set(newValue, forKey: "trashOriginals") }
    }
}

/// What kind of media a file is, from its type (Finder's view of it).
func mediaKind(of url: URL) -> MediaKind? {
    guard let t = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension) else { return nil }
    if t.conforms(to: .image) || t.conforms(to: .rawImage) { return .image }
    if t.conforms(to: .audio) { return .audio }
    if t.conforms(to: .movie) || t.conforms(to: .audiovisualContent) || t.conforms(to: .video) { return .video }
    // Types macOS doesn't know (e.g. .mkv, .opus on some systems).
    let videoExt = ["mkv", "webm", "flv", "ts", "mts", "m2ts", "vob", "wmv", "avi", "3gp", "ogv"]
    let audioExt = ["opus", "ogg", "oga", "wma", "ape", "wv", "dsf", "mka", "ac3", "dts", "amr"]
    let ext = url.pathExtension.lowercased()
    if videoExt.contains(ext) { return .video }
    if audioExt.contains(ext) { return .audio }
    return nil
}
