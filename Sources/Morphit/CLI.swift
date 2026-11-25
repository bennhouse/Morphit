import Foundation

/// Test modes without the window. Template JSON uses the same keys as templates.json; anything
/// left out is "Same as source", e.g. '{"format":"m4a","audio":{"bitrate":256,"channels":"stereo"}}'.
@MainActor
enum CLI {
    static func run(_ a: [String]) async {
        switch a[0] {
        case "--probe":
            do {
                let i = try await Probe.run(URL(fileURLWithPath: a[1]))
                print("duration \(i.duration)s, bitrate \(i.formatBitrate ?? 0), format \(i.formatName)")
                for s in i.streams {
                    print("  #\(s.index) \(s.type) \(s.codec) \(s.width)x\(s.height) \(String(format: "%.3f", s.fps))fps rot \(s.rotation) br \(s.bitrate ?? 0) \(s.sampleRate)Hz \(s.channels)ch \(s.sampleFormat) \(s.bitsPerSample)bit \(s.pixelFormat)\(s.isCover ? " cover" : "")")
                }
            } catch { print("error: \(error.localizedDescription)") }
        case "--convert", "--plan":
            guard let t = try? JSONDecoder().decode(ConversionTemplate.self, from: Data(a[1].utf8)) else {
                print("error: unreadable template JSON"); return
            }
            var files: [URL] = []
            var i = 2
            var out: URL? = nil, cpu = CPULevel.balanced, trash = false, stopAfter: Double? = nil
            while i < a.count {
                switch a[i] {
                case "--out": out = URL(fileURLWithPath: a[i + 1]); i += 2
                case "--cpu": cpu = CPULevel(rawValue: a[i + 1]) ?? .balanced; i += 2
                case "--trash": trash = true; i += 1
                case "--stop-after": stopAfter = Double(a[i + 1]); i += 2
                default: files.append(URL(fileURLWithPath: a[i])); i += 1
                }
            }
            if a[0] == "--plan" {
                for f in files {
                    do {
                        var info = try await Probe.run(f)
                        await Probe.fillMissingBitrates(&info, f)
                        let p = t.format.kind == .audio
                            ? try MediaPlan.audio(info, t, input: f, output: URL(fileURLWithPath: "OUT." + t.format.fileExtension), threads: 0)
                            : try MediaPlan.video(info, t, input: f, output: URL(fileURLWithPath: "OUT." + t.format.fileExtension), threads: 0)
                        print("ffmpeg " + p.args.joined(separator: " "))
                        for n in p.notes { print("  note: \(n)") }
                    } catch { print("error: \(error.localizedDescription)") }
                }
                return
            }
            let saved = (Prefs.outputFolder, Prefs.cpu, Prefs.trashOriginals)
            Prefs.outputFolder = out; Prefs.cpu = cpu; Prefs.trashOriginals = trash
            defer { Prefs.outputFolder = saved.0; Prefs.cpu = saved.1; Prefs.trashOriginals = saved.2 }
            let c = Converter.shared
            c.add(files)
            let start = Date()
            c.enqueue(c.jobs, t)
            if let stopAfter {   // test of Stop: no partial file may remain, originals untouched
                Task { try? await Task.sleep(for: .seconds(stopAfter)); c.stop() }
            }
            while c.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            for j in c.jobs {
                switch j.status {
                case .done(let u): print("OK   \(j.url.lastPathComponent) → \(u.lastPathComponent)\(j.trashed ? " (original trashed)" : "")\(j.note.map { "  [\($0)]" } ?? "")")
                case .failed(let m): print("FAIL \(j.url.lastPathComponent): \(m)")
                case .skipped(let m): print("SKIP \(j.url.lastPathComponent): \(m)")
                default: print("??   \(j.url.lastPathComponent): \(j.status)")
                }
            }
            print(String(format: "%.1f s", Date().timeIntervalSince(start)))
        case "--settings-roundtrip":
            // Writes the current settings and templates to FILE, reads them back and compares.
            // Changes nothing in the app's own settings.
            let url = URL(fileURLWithPath: a[1])
            do {
                var b = SettingsBackup.current()
                // Every optional set on one extra template, so the file carries all the keys.
                var full = ConversionTemplate(name: "All set", format: .webp)
                full.audio.bitrate = 192; full.audio.sampleRate = 48000; full.audio.channels = .mono; full.audio.bitDepth = 24
                full.audio.m4aCodec = .alac; full.audio.normalize = true; full.audio.bitrateMode = .variable
                full.video.codec = .av1; full.video.quality = .low; full.video.resolution = 720; full.video.frameRate = 29.97
                full.video.audio = .reencode; full.video.audioBitrate = 96; full.video.crf = 30; full.video.encoder = .software; full.video.bitrate = 4000
                full.image.quality = 70; full.image.resize = .megapixels; full.image.resizeValue = 2.5; full.image.metadata = .removeLocation
                full.image.color = .sRGB; full.image.tiffCompression = .none; full.image.lossless = true; full.image.enlarge = true
                b.templates.append(full)
                try b.write(url)
                let back = try SettingsBackup.read(url)
                print(back.templates == b.templates && back.cpuLevel == b.cpuLevel && back.outputFolder == b.outputFolder
                      && back.trashOriginals == b.trashOriginals ? "OK   \(back.templates.count) templates, settings identical" : "FAIL differs")
            } catch { print("error: \(error.localizedDescription)") }
            let bad = URL(fileURLWithPath: a[1] + ".bad.json")
            try? Data("{\"hello\":1}".utf8).write(to: bad)
            do { _ = try SettingsBackup.read(bad); print("FAIL accepted a foreign file") } catch { print("OK   foreign file refused: \(error.localizedDescription)") }
        default:
            break
        }
    }
}
