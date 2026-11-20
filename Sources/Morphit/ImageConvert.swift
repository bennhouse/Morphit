import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image conversion. macOS (ImageIO) reads every image (RAW, HEIC, AVIF, WebP, PSD…) and writes
/// JPEG, PNG, HEIC, HEIF, TIFF and BMP with their metadata. WebP and AVIF, which macOS can't write,
/// are encoded by ffmpeg (libwebp, libaom) from an sRGB PNG, without metadata.
enum ImageConvert {
    struct Info {
        var width: Int, height: Int       // as displayed (orientation applied)
        var hasAlpha: Bool
        var typeID: String
        var depth: Int
    }

    static func info(_ url: URL) -> Info? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return Info(width: o >= 5 ? h : w, height: o >= 5 ? w : h, hasAlpha: p[kCGImagePropertyHasAlpha] as? Bool ?? false,
                    typeID: CGImageSourceGetType(src) as String? ?? "", depth: p[kCGImagePropertyDepth] as? Int ?? 8)
    }

    /// Scale factor for the resize settings (1 = unchanged).
    static func scale(width w: Int, height h: Int, _ s: ImageSettings) -> Double {
        let v = s.resizeValue
        guard v > 0 else { return 1 }
        var f: Double
        switch s.resize {
        case .none: return 1
        case .longSide: f = v / Double(max(w, h))
        case .shortSide: f = v / Double(min(w, h))
        case .megapixels: f = sqrt(v * 1_000_000 / Double(w * h))
        case .percent: f = v / 100
        }
        if !s.enlarge { f = min(f, 1) }
        return f
    }

    static func outputSize(width w: Int, height h: Int, _ s: ImageSettings) -> (Int, Int) {
        let f = scale(width: w, height: h, s)
        return (max(1, Int((Double(w) * f).rounded())), max(1, Int((Double(h) * f).rounded())))
    }

    /// Converts one image. `qos` sets the priority of ffmpeg for WebP / AVIF.
    static func convert(_ input: URL, to output: URL, _ t: ConversionTemplate, threads: Int, qos: QualityOfService) async throws {
        let s = t.image
        guard let src = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let original = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw ToolError(message: "macOS can’t read this image.")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = CGImagePropertyOrientation(rawValue: UInt32(props[kCGImagePropertyOrientation] as? Int ?? 1)) ?? .up
        let hasAlpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
        let srcType = CGImageSourceGetType(src) as String? ?? ""

        // Pixels: orientation baked in (the output is upright everywhere, with orientation 1), then
        // resized with Lanczos, flattened on white for formats without transparency, and converted
        // to sRGB when asked (always for the ffmpeg formats, which ignore colour profiles).
        let viaFFmpeg = t.format.imageViaFFmpeg
        let keepsAlpha = [.png, .heic, .heif, .webp, .tiff].contains(t.format)
        let toSRGB = s.color == .sRGB || viaFFmpeg
        let (dw, dh) = orientation.rawValue >= 5 ? (original.height, original.width) : (original.width, original.height)
        let f = scale(width: dw, height: dh, s)
        let needsWork = orientation != .up || abs(f - 1) > 1e-6 || (hasAlpha && !keepsAlpha) || toSRGB
        var image = original
        if needsWork {
            var ci = CIImage(cgImage: original).oriented(orientation)
            if abs(f - 1) > 1e-6 {
                let tw = max(1, (Double(dw) * f).rounded()), th = max(1, (Double(dh) * f).rounded())
                let lz = CIFilter(name: "CILanczosScaleTransform")!
                lz.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
                lz.setValue(th / Double(dh), forKey: kCIInputScaleKey)
                lz.setValue((tw / Double(dw)) / (th / Double(dh)), forKey: kCIInputAspectRatioKey)
                ci = lz.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: tw, height: th))
            }
            if hasAlpha && !keepsAlpha {
                ci = ci.composited(over: CIImage(color: .white).cropped(to: ci.extent))
            }
            let cs = toSRGB ? CGColorSpace(name: CGColorSpace.sRGB)! : (original.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
            let deep = original.bitsPerComponent > 8 && !viaFFmpeg && ![.jpg, .bmp].contains(t.format)
            let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
            guard let rendered = ctx.createCGImage(ci, from: ci.extent.integral, format: deep ? .RGBA16 : .RGBA8, colorSpace: cs) else {
                throw ToolError(message: "The image couldn’t be processed.")
            }
            image = rendered
        }

        // Quality: "Same as source" is the source JPEG's own quality, estimated from its tables;
        // 90 for other lossy sources, 95 for lossless ones.
        let quality = s.quality ?? estimatedQuality(input, sourceType: srcType)

        if viaFFmpeg {
            try await encodeWithFFmpeg(image, to: output, format: t.format, quality: quality, lossless: s.lossless,
                                       hasAlpha: hasAlpha, threads: threads, qos: qos)
            return
        }

        let typeID: String
        switch t.format {
        case .jpg: typeID = UTType.jpeg.identifier
        case .png: typeID = UTType.png.identifier
        case .heic, .heif: typeID = UTType.heic.identifier
        case .tiff: typeID = UTType.tiff.identifier
        case .bmp: typeID = UTType.bmp.identifier
        default: throw ToolError(message: "\(t.format.title) isn’t an image format.")
        }
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, typeID as CFString, 1, nil) else {
            throw ToolError(message: "Can’t write \(output.lastPathComponent).")
        }

        var opts: [CFString: Any] = [:]
        if t.format.isLossyImage { opts[kCGImageDestinationLossyCompressionQuality] = Double(quality) / 100 }
        if t.format == .tiff {
            let srcCompression = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFCompression] as? Int
            let c = s.tiffCompression?.tag ?? (srcCompression == 1 ? 1 : 5)
            opts[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: c]
        }

        var meta: CGImageMetadata? = nil
        if s.metadata != .removeAll, let m = CGImageSourceCopyMetadataAtIndex(src, 0, nil), let mm = CGImageMetadataCreateMutableCopy(m) {
            if s.metadata == .removeLocation { stripLocation(mm) }
            // Pixels are upright now, and the size may have changed.
            CGImageMetadataSetValueMatchingImageProperty(mm, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber)
            CGImageMetadataSetValueMatchingImageProperty(mm, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension, image.width as CFNumber)
            CGImageMetadataSetValueMatchingImageProperty(mm, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelYDimension, image.height as CFNumber)
            meta = mm
        }
        opts[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImageAndMetadata(dest, image, meta, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError(message: "macOS couldn’t write the \(t.format.title) file.") }
    }

    /// Removes GPS tags (EXIF GPS and XMP exif:GPS…).
    static func stripLocation(_ m: CGMutableImageMetadata) {
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(m, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
            let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
            let prefix = CGImageMetadataTagCopyPrefix(tag) as String? ?? ""
            if name.hasPrefix("GPS") || prefix == "exifEX" && name.hasPrefix("GPS") || (prefix == "photoshop" && ["City", "State", "Country"].contains(name))
                || (prefix == "Iptc4xmpCore" && ["Location", "CountryCode"].contains(name)) {
                paths.append(path as String)
            }
            return true
        }
        for p in paths { CGImageMetadataRemoveTagWithPath(m, nil, p as CFString) }
    }

    private static func encodeWithFFmpeg(_ image: CGImage, to output: URL, format: OutputFormat, quality: Int, lossless: Bool,
                                         hasAlpha: Bool, threads: Int, qos: QualityOfService) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("morphit-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let d = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ToolError(message: "Can’t prepare the image.")
        }
        CGImageDestinationAddImage(d, image, nil)
        guard CGImageDestinationFinalize(d) else { throw ToolError(message: "Can’t prepare the image.") }

        var args = ["-y", "-i", tmp.path, "-threads", "\(threads)", "-frames:v", "1"]
        if format == .webp {
            if lossless {
                args += ["-c:v", "libwebp", "-lossless", "1", "-quality", "100", "-compression_level", "6", "-pix_fmt", hasAlpha ? "bgra" : "bgra"]
            } else {
                args += ["-c:v", "libwebp", "-quality", "\(quality)", "-compression_level", "6", "-pix_fmt", hasAlpha ? "yuva420p" : "yuv420p"]
            }
            args += ["-f", "webp", output.path]
        } else {
            // AVIF still picture: 4:4:4 (no odd-size or colour-bleeding issues), CRF from the quality.
            let crf = max(0, min(63, Int((Double(100 - quality) * 0.6 + 10).rounded())))
            args += ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", "\(crf)", "-b:v", "0", "-cpu-used", "6",
                     "-pix_fmt", "yuv444p", "-color_primaries", "bt709", "-color_trc", "iec61966-2-1", "-colorspace", "bt709",
                     "-f", "avif", output.path]
        }
        try await runFFmpeg(args, qos: qos) { _ in }
    }

    /// Quality the source JPEG was saved at, estimated from its luminance quantisation table
    /// (the IJG scale). 90 for other lossy formats, 95 for lossless ones.
    static func estimatedQuality(_ url: URL, sourceType: String) -> Int {
        let type = UTType(sourceType)
        if type?.conforms(to: .jpeg) == true, let q = jpegQuality(url) { return q }
        if let type, type.conforms(to: .png) || type.conforms(to: .tiff) || type.conforms(to: .bmp) || type.conforms(to: .rawImage) { return 95 }
        return 90
    }

    static func jpegQuality(_ url: URL) -> Int? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 256 * 1024) else { return nil }
        let b = [UInt8](data)
        let std: [Int] = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
                          14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
                          49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]
        var i = 2
        while i + 4 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let marker = b[i + 1]
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if marker == 0xDB {
                var j = i + 4
                while j < i + 2 + len, j < b.count {
                    let pq = b[j] >> 4, tq = b[j] & 15
                    let n = pq == 0 ? 64 : 128
                    guard j + 1 + n <= b.count else { return nil }
                    if tq == 0 {
                        var sum = 0
                        for k in 0..<64 {
                            sum += pq == 0 ? Int(b[j + 1 + k]) : (Int(b[j + 1 + 2 * k]) << 8 | Int(b[j + 2 + 2 * k]))
                        }
                        // table = std * scale / 100, scale = 5000/q (q < 50) or 200 - 2q.
                        let scale = Double(sum) * 100 / Double(std.reduce(0, +))
                        let q = scale <= 100 ? (200 - scale) / 2 : 5000 / scale
                        return max(1, min(100, Int(q.rounded())))
                    }
                    j += 1 + n
                }
            }
            if marker == 0xDA { break }   // start of scan: no tables after this
            i += 2 + len
        }
        return nil
    }
}
