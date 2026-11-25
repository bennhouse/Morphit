import AppKit

/// Development aid: with MORPHIT_SNAPSHOT=<folder> (MORPHIT_SNAPSHOT_ADVANCED=video|audio|image
/// opens that group's settings; MORPHIT_SNAPSHOT_OPEN=templates|general opens Settings) in the environment, Morphit writes a PNG of each of
/// its windows (toolbar included) every second, so the layout can be checked without screen
/// recording permission. Does nothing otherwise.
@MainActor
enum Snapshots {
    private static var timer: Timer?

    static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["MORPHIT_SNAPSHOT"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // MORPHIT_FRAMELOG=1: window sizes every 10 ms in <dir>/frames.log, to check that resizes animate.
        if env["MORPHIT_FRAMELOG"] != nil {
            let log = URL(fileURLWithPath: dir).appendingPathComponent("frames.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let h = try? FileHandle(forWritingTo: log)
            let start = Date()
            // Read from the window server on a background thread: AppKit's resize animation keeps
            // the main thread busy, so a main-thread timer would miss the intermediate sizes.
            let pid = ProcessInfo.processInfo.processIdentifier
            let burst = env["MORPHIT_FRAMELOG"] == "burst"
            if burst { try? FileManager.default.createDirectory(atPath: dir + "/burst", withIntermediateDirectories: true) }
            Thread.detachNewThread {
                var firstSeen: [Int: Double] = [:]
                while true {
                    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
                    let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
                    let line = mine.compactMap { w -> String? in
                        guard let b = w[kCGWindowBounds as String] as? [String: Any] else { return nil }
                        let on = (w[kCGWindowIsOnscreen as String] as? Bool) == true
                        let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
                        return "\(Int(b["Width"] as? Double ?? 0))x\(Int(b["Height"] as? Double ?? 0))@\(Int(b["X"] as? Double ?? 0))\(on ? "" : "(off)")\(alpha < 1 ? String(format: "(a%.1f)", alpha) : "")"
                    }.joined(separator: " ")
                    h?.write(Data(String(format: "%.3f %@\n", Date().timeIntervalSince(start), line).utf8))
                    // MORPHIT_FRAMELOG=burst: also the real pixels of each window opened after launch,
                    // every frame for its first 1.5 s, in <dir>/burst (to see how a window appears).
                    if burst {
                        let now = Date().timeIntervalSince(start)
                        for w in mine {
                            guard let n = w[kCGWindowNumber as String] as? Int else { continue }
                            // Restarts each time the window comes (back) on screen, visible.
                            let shown = (w[kCGWindowIsOnscreen as String] as? Bool) == true && (w[kCGWindowAlpha as String] as? Double ?? 1) > 0
                            if !shown { firstSeen[n] = nil; continue }
                            if firstSeen[n] == nil { firstSeen[n] = now }
                            guard let t0 = firstSeen[n], now - t0 < 1.5, let img = WindowCapture.image(n, nominal: true) else { continue }
                            let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "burst/%d-%05d-%04d.png", n, Int(t0 * 1000), Int((now - t0) * 1000)))
                            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }
        // MORPHIT_FRAMELOG: also the window with the focus every 20 ms, in <dir>/key.log.
        if env["MORPHIT_FRAMELOG"] != nil {
            let start = Date()
            FileManager.default.createFile(atPath: dir + "/key.log", contents: nil)
            let kh = FileHandle(forWritingAtPath: dir + "/key.log")
            Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let key = NSApp.keyWindow.map { $0.title.isEmpty ? "main" : $0.title } ?? "none"
                    kh?.write(Data(String(format: "%.3f %@\n", Date().timeIntervalSince(start), key).utf8))
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                // Which window has the focus (to check that nothing steals it).
                let key = NSApp.keyWindow.map { $0.title.isEmpty ? "main window" : $0.title } ?? "none"
                try? (key + "\n").write(toFile: "\(dir)/key.txt", atomically: true, encoding: .utf8)
                for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                    guard let frameView = w.contentView?.superview else { continue }
                    let b = frameView.bounds
                    guard let rep = frameView.bitmapImageRepForCachingDisplay(in: b) else { continue }
                    frameView.cacheDisplay(in: b, to: rep)
                    let name = w.title.isEmpty ? "window\(i)" : w.title.replacingOccurrences(of: " ", with: "-")
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                    // The window as the window server composites it (materials, vibrancy), which
                    // cacheDisplay doesn't draw. An app may capture its own windows without permission.
                    if let img = WindowCapture.image(w.windowNumber) {
                        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: "\(dir)/\(name)-screen.png"))
                    }
                }
            }
        }
    }
}

/// CGWindowListCreateImage, looked up at run time: the macOS 15 SDK marks it unavailable, but it
/// still works for an app's own windows, which is all the snapshots need.
enum WindowCapture {
    private typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let fn: Fn? = {
        guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func image(_ windowNumber: Int, nominal: Bool = false) -> CGImage? {
        // includingWindow = 1 << 3; boundsIgnoreFraming = 1, bestResolution = 1 << 3, nominal = 1 << 4
        fn?(.null, 1 << 3, UInt32(windowNumber), 1 | (nominal ? 1 << 4 : 1 << 3))?.takeRetainedValue()
    }
}
