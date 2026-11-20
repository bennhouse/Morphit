import AppKit
import SwiftUI

enum SettingsTab: String {
    case general, templates
    /// Set before opening Settings to show a given tab ("Edit Templates…").
    @MainActor static var requested: SettingsTab?
}

struct SettingsView: View {
    @State private var tab: SettingsTab = .general
    @State private var window: NSWindow?
    /// The tab's content is hidden while the window changes size, then fades in (as in System Settings).
    @State private var contentOpacity = 1.0
    @State private var resizeID = 0

    /// Each tab has its own size.
    private func size(_ t: SettingsTab) -> CGSize {
        switch t {
        case .general: CGSize(width: 500, height: 214)
        case .templates: CGSize(width: 580, height: 400)
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            page(GeneralSettings(), .general)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            page(TemplatesSettings(), .templates)
                .tabItem { Label("Templates", systemImage: "square.stack.3d.up") }
                .tag(SettingsTab.templates)
        }
        // Flexible, so the window decides the size and SwiftUI follows it; the ideal size makes
        // the window open at the right size straight away (no jump on the first opening).
        .frame(minWidth: 0, idealWidth: size(tab).width, maxWidth: .infinity,
               minHeight: 0, idealHeight: size(tab).height, maxHeight: .infinity)
        .background(WindowReader { w in
            guard window !== w else { return }
            window = w
            w.titlebarSeparatorStyle = .line
            TitlebarMaterial.install(in: w)
            resize(animated: false)
            SettingsPreload.hideIfPreloading(w)
        })
        .onChange(of: tab) { resize(animated: true) }
        .onAppear {
            takeRequest()
            // Development aid with MORPHIT_SNAPSHOT: MORPHIT_SNAPSHOT_CYCLE=1 switches tab every 2 s.
            let env = ProcessInfo.processInfo.environment
            if env["MORPHIT_SNAPSHOT"] != nil, env["MORPHIT_SNAPSHOT_CYCLE"] != nil {
                Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                    MainActor.assumeIsolated { tab = tab == .general ? .templates : .general }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in takeRequest() }
    }

    /// A tab's content at its own fixed size, pinned to the top: it doesn't reflow while the window
    /// grows or shrinks around it.
    private func page<V: View>(_ v: V, _ t: SettingsTab) -> some View {
        v.frame(width: size(t).width, height: size(t).height)
            .opacity(contentOpacity)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
            // The same top bar on every tab. Each tab is hosted on its own, so this goes on each page:
            // macOS otherwise shows the bar's material only when something scrolls under it (the
            // Templates list), and General's bar took the window colour instead.
            .toolbarBackground(.visible, for: .windowToolbar)
    }

    /// Hides the content, resizes the window (AppKit, ease-in-out), then fades the new content in.
    /// The top edge stays in place.
    private func resize(animated: Bool) {
        guard let w = window else { return }
        let target = size(tab)
        let chromeH = w.frame.height - w.contentLayoutRect.height
        let chromeW = w.frame.width - w.contentLayoutRect.width
        let newSize = CGSize(width: target.width + chromeW, height: target.height + chromeH)
        let frame = NSRect(x: w.frame.minX, y: w.frame.maxY - newSize.height, width: newSize.width, height: newSize.height)
        guard animated, w.isVisible, newSize != w.frame.size else {
            w.setFrame(frame, display: true)
            contentOpacity = 1
            return
        }
        resizeID += 1
        let id = resizeID
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { contentOpacity = 0 }
        // AppKit's own resize (ease-in-out) keeps the title bar and the tab bar drawn the whole time;
        // a Core Animation resize redraws them and they vanish for a moment. It starts on the next
        // turn of the run loop, once the hidden content has been drawn.
        DispatchQueue.main.async {
            guard id == resizeID else { return }
            w.setFrame(frame, display: true, animate: true)
            guard id == resizeID else { return }   // a newer switch is under way
            withAnimation(.easeOut(duration: 0.18)) { contentOpacity = 1 }
        }
    }

    private func takeRequest() {
        if let r = SettingsTab.requested { tab = r; SettingsTab.requested = nil }
    }
}

/// The top bar's material under the title and the tabs, on every tab. macOS draws its own only when
/// a sidebar or scrolled content sits under the bar (Templates), and leaves the bar in the window
/// colour otherwise (General), so the two tabs had different bars.
@MainActor
enum TitlebarMaterial {
    private static let id = NSUserInterfaceItemIdentifier("morphitTitlebarMaterial")

    static func install(in w: NSWindow) {
        guard let bar = w.standardWindowButton(.closeButton)?.superview,
              !bar.subviews.contains(where: { $0.identifier == id }) else { return }
        let v = NSVisualEffectView(frame: bar.bounds)
        v.identifier = id
        v.material = .titlebar
        v.blendingMode = .withinWindow
        v.state = .followsWindowActiveState
        v.autoresizingMask = [.width, .height]
        // An opaque window-coloured base under it: the material blends with what is behind it in
        // the window, and on Templates that was the lighter sidebar. With this base it looks the
        // same on every tab, and still follows light/dark and active/inactive.
        let base = NSBox(frame: bar.bounds)
        base.boxType = .custom
        base.borderWidth = 0
        base.fillColor = .windowBackgroundColor
        base.autoresizingMask = [.width, .height]
        // Above the system's own bar backgrounds (shown on some tabs only), below the title and
        // the tab buttons: the colour is always this one.
        let firstControl = bar.subviews.first { $0 is NSTextField || $0.className.contains("Toolbar") || $0.className.contains("Widget") }
        bar.addSubview(base, positioned: .below, relativeTo: firstControl)
        bar.addSubview(v, positioned: .above, relativeTo: base)
    }
}

/// Hands over the NSWindow a view is in.
/// The Settings window is built once, invisibly, right after launch: when it is opened, its contents
/// are already loaded and laid out, and the opening animation starts on the finished window.
/// While preloading it is transparent, ignores the mouse and gives the focus straight back to the
/// main window, so nothing changes on screen.
@MainActor
enum SettingsPreload {
    private(set) static var active = false
    private static var done = false
    private weak static var main: NSWindow?
    private static var observer: NSObjectProtocol?

    static func start(_ open: () -> Void) {
        guard !done, !active else { return }
        done = true
        active = true
        main = NSApp.keyWindow ?? NSApp.mainWindow
        // Registered before the window exists: whatever window becomes key while preloading,
        // the main window takes the focus back in the same turn of the run loop.
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard active, let m = main, (note.object as? NSWindow) !== m else { return }
                m.makeKeyAndOrderFront(nil)
            }
        }
        open()
    }

    /// Called when the Settings window gets its contents, before it is first shown.
    static func hideIfPreloading(_ w: NSWindow) {
        guard active else { return }
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        if w.isKeyWindow { main?.makeKeyAndOrderFront(nil) }
        // Long enough for SwiftUI to build and draw everything once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let o = observer { NotificationCenter.default.removeObserver(o) }
            observer = nil
            w.orderOut(nil)
            w.alphaValue = 1
            w.ignoresMouseEvents = false
            active = false
            if NSApp.keyWindow == nil { main?.makeKeyAndOrderFront(nil) }
        }
    }
}

/// Called as soon as the view is put in a window, before the window is first shown, so the window
/// can be sized without being seen at SwiftUI's default size first.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { onWindow?(w) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.onWindow = onWindow
        return v
    }
    func updateNSView(_ view: Probe, context: Context) {
        view.onWindow = onWindow
    }
}

// MARK: - General

struct GeneralSettings: View {
    @AppStorage("cpuLevel") private var cpu: CPULevel = .balanced
    @AppStorage("outputFolder") private var outputFolder: String = ""
    @AppStorage("trashOriginals") private var trashOriginals = false

    var body: some View {
        // One compact group; the longer explanations are in the tooltips.
        Form {
            LabeledContent("Save to") {
                HStack(spacing: 6) {
                    Text(outputFolder.isEmpty ? "Next to the originals" : (outputFolder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    if !outputFolder.isEmpty {
                        Button { outputFolder = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("Back to: next to the originals")
                    }
                    Button("Choose…") { chooseFolder() }
                }
            }
            .help("An existing file is never replaced: the new one gets a number, like “Song 2.mp3”.")
            LabeledContent("CPU usage") {
                Picker("CPU usage", selection: $cpu) {
                    ForEach(CPULevel.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .help(cpu.help + " " + details)
            Toggle("Move originals to the Trash after converting", isOn: $trashOriginals)
                .help("Only after the file has been converted and saved. Never when a conversion fails or is stopped, and never deleted outright.")
            LabeledContent("Settings and templates") {
                HStack(spacing: 6) {
                    Button("Import…") { SettingsTransfer.importFile() }
                    Button("Export…") { SettingsTransfer.export() }
                }
            }
            .help("One file with these settings and every template: keep a copy, or move them to another Mac.")
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var details: String {
        let jobs = cpu.parallelJobs
        let threads = cpu.threadsPerJob == 0 ? "all cores" : "\(cpu.threadsPerJob) threads"
        return "On this Mac: \(jobs) \(jobs == 1 ? "file" : "files") at a time, \(threads) each."
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Choose"
        if p.runModal() == .OK, let u = p.url { outputFolder = u.path }
    }
}

// MARK: - Templates

struct TemplatesSettings: View {
    @State private var store = TemplateStore.shared
    @State private var selection: UUID?
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(MediaKind.allCases) { kind in
                        let list = store.templates.filter { $0.format.kind == kind }
                        if !list.isEmpty {
                            Section(kind.title) {
                                ForEach(list) { t in
                                    Text(t.name)
                                        .help(t.summary)
                                    .tag(t.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .environment(\.defaultMinListRowHeight, 22)
                .scrollIndicators(.never)
                Divider()
                HStack(spacing: 2) {
                    Menu {
                        ForEach(MediaKind.allCases) { kind in
                            Section(kind.title) {
                                ForEach(OutputFormat.formats(kind)) { f in
                                    Button(f.title) { selection = store.add(ConversionTemplate(name: f.title, format: f)).id }
                                }
                            }
                        }
                    } label: { Image(systemName: "plus") }
                    .menuIndicator(.hidden)
                    .help("New template")
                    Button { if let t = selected { selection = store.duplicate(t).id } } label: { Image(systemName: "plus.square.on.square") }
                        .help("Duplicate").disabled(selected == nil)
                    Button { confirmDelete = true } label: { Image(systemName: "minus") }
                        .help("Delete").disabled(selected == nil)
                    Spacer()
                    Menu {
                        Button("Add Missing Built-in Templates") { store.restoreDefaults() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuIndicator(.hidden)
                }
                .buttonStyle(.borderless)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .frame(width: 150)
            Divider()
            if let binding = selectedBinding {
                TemplateEditor(t: binding).id(selection)
            } else {
                ContentUnavailableView("No Template Selected", systemImage: "square.stack.3d.up",
                                       description: Text("Choose a template, or add one with +."))
            }
        }
        .onAppear { if selection == nil { selection = store.selectedID ?? store.templates.first?.id } }
        .confirmationDialog("Delete “\(selected?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                guard let t = selected else { return }
                let i = store.templates.firstIndex(of: t) ?? 0
                store.delete(t)
                selection = store.templates[min(i, store.templates.count - 1)].id
            }
        } message: {
            Text("The template is removed. Files already converted with it stay as they are.")
        }
    }

    private var selected: ConversionTemplate? { store.template(selection) }

    private var selectedBinding: Binding<ConversionTemplate>? {
        guard let t = selected else { return nil }
        return Binding(get: { store.template(t.id) ?? t }, set: { store.update($0) })
    }
}

struct TemplateEditor: View {
    @Binding var t: ConversionTemplate

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $t.name)
                Picker("Format", selection: $t.format) {
                    ForEach(MediaKind.allCases) { kind in
                        Section(kind.title) {
                            ForEach(OutputFormat.formats(kind)) { f in Text(f.title).tag(f) }
                        }
                    }
                }
                .help(t.format.detail)
            }
            ParameterForm(t: $t, collapsible: true)
        }
        .formStyle(.grouped)
        .contentMargins(.horizontal, 10, for: .scrollContent)
        .contentMargins(.vertical, 6, for: .scrollContent)
    }
}
