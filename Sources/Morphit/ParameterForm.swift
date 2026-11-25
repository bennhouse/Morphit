import SwiftUI

/// The parameters of a template, for its format: the everyday ones first, the technical ones in
/// "Advanced settings". Used in the template editor and in the main window.
struct ParameterForm: View {
    @Binding var t: ConversionTemplate
    /// true: the advanced rows sit in a collapsed "Advanced settings" group.
    var collapsible = true
    @State private var advancedOpen = false

    var body: some View {
        Section {
            switch t.format.kind {
            case .audio: AudioBase(t: $t)
            case .video: VideoBase(t: $t)
            case .image: ImageBase(t: $t)
            }
        }
        Section {
            if collapsible {
                DisclosureGroup(isExpanded: $advancedOpen) { advanced } label: {
                    // The title opens and closes the group too, not only the arrow.
                    Text("Advanced settings")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.smooth(duration: 0.25)) { advancedOpen.toggle() } }
                }
            } else {
                advanced
            }
        } header: {
            if !collapsible { Text("Advanced") }
        }
    }

    @ViewBuilder private var advanced: some View {
        switch t.format.kind {
        case .audio: AudioAdvanced(t: $t)
        case .video: VideoAdvanced(t: $t)
        case .image: ImageAdvanced(t: $t)
        }
    }
}

private let sameAsSource = "Same as source"

// MARK: - Audio

private struct AudioBase: View {
    @Binding var t: ConversionTemplate

    var body: some View {
        let lossy = t.format.isLossyAudio && !(t.format == .m4a && t.audio.m4aCodec == .alac)
        if lossy {
            Picker("Bitrate", selection: $t.audio.bitrate) {
                Text(sameAsSource).tag(Int?.none)
                Divider()
                ForEach(t.format == .opus ? AudioSettings.opusBitrates : AudioSettings.bitrates, id: \.self) {
                    Text("\($0) kbps").tag(Int?.some($0))
                }
            }
            .help("Same as source: the bitrate of the original (320 kbps for lossless sources), within what the format allows.")
        }
        Picker("Sample rate", selection: $t.audio.sampleRate) {
            Text(sameAsSource).tag(Int?.none)
            Divider()
            ForEach(rates, id: \.self) { Text(String(format: "%g kHz", Double($0) / 1000)).tag(Int?.some($0)) }
        }
        Picker("Channels", selection: $t.audio.channels) {
            ForEach(ChannelMode.allCases) { Text($0.title).tag($0) }
        }
    }

    private var rates: [Int] {
        switch t.format {
        case .mp3, .aac: AudioSettings.sampleRates.filter { $0 <= 48000 }
        case .m4a where t.audio.m4aCodec == .aac: AudioSettings.sampleRates.filter { $0 <= 48000 }
        case .opus: [24000, 48000]
        default: AudioSettings.sampleRates
        }
    }
}

private struct AudioAdvanced: View {
    @Binding var t: ConversionTemplate

    var body: some View {
        let f = t.format
        if f == .m4a {
            Picker("Codec", selection: $t.audio.m4aCodec) {
                ForEach(M4ACodec.allCases) { Text($0.title).tag($0) }
            }
        }
        if [.mp3, .aac, .opus].contains(f) || (f == .m4a && t.audio.m4aCodec == .aac) {
            Picker("Bitrate mode", selection: $t.audio.bitrateMode) {
                ForEach(BitrateMode.allCases) { Text($0.title).tag($0) }
            }
        }
        if f == .wav || f == .flac || (f == .m4a && t.audio.m4aCodec == .alac) {
            Picker("Bit depth", selection: $t.audio.bitDepth) {
                Text(sameAsSource).tag(Int?.none)
                Divider()
                Text("16-bit").tag(Int?.some(16))
                Text("24-bit").tag(Int?.some(24))
                if f == .wav { Text("32-bit float").tag(Int?.some(32)) }
            }
        }
        if f == .flac {
            Stepper(value: $t.audio.flacLevel, in: 0...12) {
                LabeledContent("Compression level", value: "\(t.audio.flacLevel)\(t.audio.flacLevel == 5 ? " (standard)" : "")")
            }
            .help("Higher levels make slightly smaller files and take longer. The sound is identical.")
        }
        Toggle("Loudness normalisation (EBU R128, −16 LUFS)", isOn: $t.audio.normalize)
        Toggle("Keep tags (title, artist, album…)", isOn: $t.audio.keepMetadata)
        if [.mp3, .m4a, .flac].contains(f) {
            Toggle("Keep cover art", isOn: $t.audio.keepCover)
        }
    }
}

// MARK: - Video

private struct VideoBase: View {
    @Binding var t: ConversionTemplate

    var body: some View {
        let f = t.format
        if f.videoCodecs.count > 1 {
            Picker("Codec", selection: $t.video.codec) {
                Text(sameAsSource).tag(VideoCodec?.none)
                Divider()
                ForEach(f.videoCodecs) { Text($0.title).tag(VideoCodec?.some($0)) }
            }
            .help("Same as source: the original codec is kept when \(f.title) can hold it (no re-encoding, no loss); otherwise \(f.videoCodecs[0].title).")
        }
        if f != .gif && t.video.codec != .prores {
            Picker("Quality", selection: Binding(get: { t.video.quality }, set: { q in
                t.video.quality = q
                if q == .custom, t.video.bitrate == nil { t.video.bitrate = range.medium }
            })) {
                ForEach(VideoQuality.allCases) { q in
                    if q == .custom { Divider() }
                    Text(q.title).tag(q)
                }
            }
            .help("Same as source: the original's bitrate (the stream is copied when nothing else changes). High, Medium and Small file use constant quality. Custom bitrate: choose the kbps within a range that suits the resolution, frame rate and codec.")
            if t.video.quality == .custom {
                BitrateSlider(kbps: Binding(get: { t.video.bitrate ?? range.medium }, set: { t.video.bitrate = $0 }), range: range)
            }
        }
        Picker("Resolution", selection: $t.video.resolution) {
            Text(sameAsSource).tag(Int?.none)
            Divider()
            ForEach(VideoSettings.resolutions, id: \.self) { Text(label($0)).tag(Int?.some($0)) }
        }
        .help("Fits the short side; vertical videos stay vertical. Never enlarged.")
        Picker("Frame rate", selection: $t.video.frameRate) {
            Text(sameAsSource).tag(Double?.none)
            Divider()
            ForEach(VideoSettings.frameRates, id: \.self) { Text("\(formatNumber($0)) fps").tag(Double?.some($0)) }
        }
        if f != .gif {
            Picker("Audio track", selection: $t.video.audio) {
                ForEach(AudioTrackMode.allCases) { Text($0.title).tag($0) }
            }
            .help("Same as source: copied when \(f.title) takes it, otherwise converted to \(f == .webm ? "Opus" : "AAC") at the original bitrate.")
            if t.video.audio == .reencode {
                Picker("Audio bitrate", selection: $t.video.audioBitrate) {
                    Text(sameAsSource).tag(Int?.none)
                    Divider()
                    ForEach(AudioSettings.bitrates, id: \.self) { Text("\($0) kbps").tag(Int?.some($0)) }
                }
            }
        }
    }

    private var range: BitrateRange {
        BitrateRange(codec: t.video.codec, format: t.format, resolution: t.video.resolution, frameRate: t.video.frameRate)
    }

    private func label(_ r: Int) -> String {
        switch r {
        case 2160: "2160p (4K)"
        case 1440: "1440p"
        default: "\(r)p"
        }
    }
}

/// Video bitrate in kbps, within the range that makes sense for the other settings. The scale is
/// logarithmic (each step of the slider is the same proportion), with marks for the three presets.
private struct BitrateSlider: View {
    @Binding var kbps: Int
    let range: BitrateRange

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Bitrate") {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { position(kbps) }, set: { kbps = value($0) }), in: 0...1)
                        .frame(minWidth: 140)
                    Text(verbatim: formatKbps(kbps)).monospacedDigit().frame(width: 72, alignment: .trailing)
                }
            }
            HStack {
                Text(verbatim: range.label(kbps))
                Spacer()
                Text(verbatim: "\(formatKbps(range.min)) – \(formatKbps(range.max)) for \(String(range.shortSide))p · \(formatNumber(range.fps)) fps · \(range.codec.title)\(range.assumed ? " source" : "")")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        // A range that changed (resolution, frame rate, codec) keeps the value inside it.
        .onChange(of: range.max) { kbps = min(max(kbps, range.min), range.max) }
        .onChange(of: range.min) { kbps = min(max(kbps, range.min), range.max) }
        .help(range.assumed ? "With resolution or frame rate “Same as source”, the range is shown for a 1080p, 30 fps source; the bitrate is scaled to the real picture size." : "Bits per second of video. Higher: better quality and larger files.")
    }

    private func position(_ k: Int) -> Double {
        let lo = log(Double(range.min)), hi = log(Double(range.max))
        return min(max((log(Double(max(k, 1))) - lo) / (hi - lo), 0), 1)
    }

    private func value(_ p: Double) -> Int {
        let lo = log(Double(range.min)), hi = log(Double(range.max))
        return min(max(BitrateRange.nice(exp(lo + p * (hi - lo))), range.min), range.max)
    }
}

private struct VideoAdvanced: View {
    @Binding var t: ConversionTemplate

    var body: some View {
        let f = t.format
        if f == .gif {
            Toggle("Loop forever", isOn: $t.video.gifLoop)
        } else {
            if f != .webm && t.video.codec != .prores {
                Picker("Encoder", selection: $t.video.encoder) {
                    ForEach(EncoderChoice.allCases) { Text($0.title).tag($0) }
                }
                .help("Automatic: the Mac's hardware encoder for H.264 and HEVC (fast), software for AV1 and VP9.")
            }
            Picker("Encoding speed", selection: $t.video.speed) {
                ForEach(EncoderSpeed.allCases) { Text($0.title).tag($0) }
            }
            .help("Software encoders only. Slower makes smaller files at the same quality.")
            Toggle("Custom CRF", isOn: Binding(get: { t.video.crf != nil }, set: { t.video.crf = $0 ? 23 : nil }))
                .help("Constant Rate Factor for the software encoders: lower is better quality and larger files. Overrides Quality.")
            if let crf = t.video.crf {
                Stepper(value: Binding(get: { crf }, set: { t.video.crf = $0 }), in: 0...63) {
                    LabeledContent("CRF", value: "\(crf)")
                }
            }
            Toggle("Keep all audio tracks", isOn: $t.video.allAudioTracks)
            if f != .webm {
                Toggle("Keep subtitles", isOn: $t.video.keepSubtitles)
                    .help(f == .mkv ? "All subtitle tracks are copied." : "Text subtitles are kept; picture subtitles (Blu-ray, DVD) need MKV.")
            }
            Toggle("Keep metadata and chapters", isOn: $t.video.keepMetadata)
        }
    }
}

// MARK: - Image

private struct ImageBase: View {
    @Binding var t: ConversionTemplate

    var body: some View {
        let f = t.format
        if f.isLossyImage && !(f == .webp && t.image.lossless) {
            Picker("Quality", selection: Binding(get: { t.image.quality != nil }, set: { t.image.quality = $0 ? 85 : nil })) {
                Text(sameAsSource).tag(false)
                Text("Custom").tag(true)
            }
            .help("Same as source: a JPEG's own quality, read from the file; 90 for other compressed images, 95 for lossless ones.")
            if let q = t.image.quality {
                LabeledContent("Value") {
                    HStack {
                        Slider(value: Binding(get: { Double(q) }, set: { t.image.quality = Int($0.rounded()) }), in: 1...100)
                        Text("\(q)").monospacedDigit().frame(width: 30, alignment: .trailing)
                    }
                }
            }
        }
        Picker("Resize", selection: Binding(get: { t.image.resize }, set: {
            t.image.resize = $0
            t.image.resizeValue = $0.defaultValue
        })) {
            ForEach(ResizeMode.allCases) { m in
                Text(m.title).tag(m)
                if m == .none { Divider() }
            }
        }
        if t.image.resize != .none {
            LabeledContent(t.image.resize.title) {
                HStack(spacing: 6) {
                    TextField("", value: $t.image.resizeValue, format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .labelsHidden()
                    Text(t.image.resize.unit).foregroundStyle(.secondary)
                }
            }
        }
        Picker("Metadata", selection: $t.image.metadata) {
            ForEach(MetadataMode.allCases) { Text($0.title).tag($0) }
        }
        .disabled(f.imageViaFFmpeg)
        .help(f.imageViaFFmpeg ? "\(f.title) files are written without metadata." : "EXIF, GPS, IPTC and XMP. Remove location takes out the GPS coordinates and place names.")
    }
}

private struct ImageAdvanced: View {
    @Binding var t: ConversionTemplate

    var body: some View {
        let f = t.format
        Toggle("Allow enlarging", isOn: $t.image.enlarge)
            .help("Off: an image smaller than the target size is kept at its size.")
        Picker("Colour profile", selection: $t.image.color) {
            ForEach(ColorMode.allCases) { Text($0.title).tag($0) }
        }
        .disabled(f.imageViaFFmpeg)
        .help(f.imageViaFFmpeg ? "\(f.title) files are always converted to sRGB." : "Display P3 and other wide-gamut photos keep their profile unless converted.")
        if f == .tiff {
            Picker("Compression", selection: $t.image.tiffCompression) {
                Text(sameAsSource).tag(TIFFCompression?.none)
                Divider()
                ForEach(TIFFCompression.allCases) { Text($0.title).tag(TIFFCompression?.some($0)) }
            }
            .help("Same as source: a TIFF's own compression; LZW (lossless) for other images.")
        }
        if f == .webp {
            Toggle("Lossless", isOn: $t.image.lossless)
        }
        if f == .jpg || f == .bmp || f == .avif {
            Text("Transparent areas are filled with white: \(f.title) has no transparency.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
