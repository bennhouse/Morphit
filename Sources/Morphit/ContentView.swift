import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The list is split by kind of file (video, audio, images), and each group converts with its own
/// template: a working copy of a saved one. Changes made in a group's advanced settings apply to
/// that group until saved into the template.
@MainActor @Observable
final class AppModel {
    private(set) var drafts: [MediaKind: ConversionTemplate] = [:]
    private var edited = Set<MediaKind>()

    init() {
        for k in MediaKind.allCases { drafts[k] = Self.initial(k) }
    }

    /// Templates a group may use: video files can also become audio (the sound is extracted).
    static func kinds(for group: MediaKind) -> [MediaKind] {
        group == .video ? [.video, .audio] : [group]
    }

    private static func key(_ k: MediaKind) -> String { "selectedTemplate.\(k.rawValue)" }

    private static func initial(_ k: MediaKind) -> ConversionTemplate? {
        let store = TemplateStore.shared
        let allowed = kinds(for: k)
        if let id = UserDefaults.standard.string(forKey: key(k)).flatMap(UUID.init), let t = store.template(id),
           allowed.contains(t.format.kind) { return t }
        return store.templates.first { $0.format.kind == k }
    }

    func draft(_ k: MediaKind) -> ConversionTemplate? { drafts[k] }

    func binding(_ k: MediaKind) -> Binding<ConversionTemplate>? {
        guard let d = draft(k) else { return nil }
        return Binding(get: { self.drafts[k] ?? d }, set: { self.drafts[k] = $0; self.edited.insert(k) })
    }

    func saved(_ k: MediaKind) -> ConversionTemplate? { draft(k).flatMap { TemplateStore.shared.template($0.id) } }

    func isModified(_ k: MediaKind) -> Bool {
        guard edited.contains(k), let d = draft(k) else { return false }
        return !(saved(k).map { d.sameSettings(as: $0) } ?? false)
    }

    func select(_ t: ConversionTemplate, for k: MediaKind) {
        drafts[k] = t
        edited.remove(k)
        UserDefaults.standard.set(t.id.uuidString, forKey: Self.key(k))
    }

    func revert(_ k: MediaKind) { if let s = saved(k) { select(s, for: k) } }

    func saveToTemplate(_ k: MediaKind) {
        guard var s = saved(k), let d = draft(k) else { return }
        s.format = d.format; s.audio = d.audio; s.video = d.video; s.image = d.image
        TemplateStore.shared.update(s)
        select(s, for: k)
    }

    func saveAsNew(_ k: MediaKind, name: String) {
        guard var t = draft(k) else { return }
        t.name = name
        select(TemplateStore.shared.add(t), for: k)
    }

    /// Follows edits made in Settings to the selected templates (or their deletion).
    func templatesChanged() {
        for k in MediaKind.allCases {
            if let s = saved(k) {
                if !edited.contains(k) { drafts[k] = s } else { drafts[k]?.name = s.name }
            } else {
                drafts[k] = Self.initial(k)
                edited.remove(k)
            }
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var converter = Converter.shared
    @State private var store = TemplateStore.shared
    @State private var dropTargeted = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if converter.jobs.isEmpty {
                DropZone(targeted: dropTargeted)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(groups, id: \.id) { GroupCard(group: $0) }
                    }
                    .padding(.horizontal, Layout.gutter).padding(.top, Layout.top).padding(.bottom, Layout.gutter)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            converter.add(files)
            return true
        } isTargeted: { dropTargeted = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) { Footer() }
        .frame(minWidth: 640, minHeight: 440)
        .tone(.primary)
        .toolbar { toolbar }
        .navigationTitle("")
        .onChange(of: store.templates) { model.templatesChanged() }
        .onAppear {
            // Development aid with MORPHIT_SNAPSHOT: MORPHIT_SNAPSHOT_OPEN=templates|general opens Settings.
            let env = ProcessInfo.processInfo.environment
            if env["MORPHIT_SNAPSHOT"] != nil, let tab = env["MORPHIT_SNAPSHOT_OPEN"].flatMap(SettingsTab.init(rawValue:)) {
                SettingsTab.requested = tab
                openSettings()
            } else {
                // Builds the Settings window invisibly once the main window is up (see SettingsPreload).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { SettingsPreload.start { openSettings() } }
            }
            // MORPHIT_SNAPSHOT_CONVERT=1: converts everything 4 s after launch, to see the rows afterwards.
            if env["MORPHIT_SNAPSHOT"] != nil, env["MORPHIT_SNAPSHOT_CONVERT"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { convertAll() }
                // MORPHIT_SNAPSHOT_UNDO=<s>: then presses Undo that many seconds after launch.
                if let t = env["MORPHIT_SNAPSHOT_UNDO"].flatMap(Double.init) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                        withAnimation(.smooth(duration: 0.3)) { converter.undoLast() }
                    }
                }
            }
        }
    }

    // Title on the left like the other apps; icon buttons on the right.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 10) {
                SpinningIcon(running: converter.isRunning)
                Text("Morphit").font(.system(size: 17, weight: .bold))
            }
            .padding(.leading, 6)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { MainActions.openPanel() } label: { Label("Add Files", systemImage: "plus").toolbarIcon() }
                .help("Add files or folders (⌘O)")
            Button { converter.clearFinished() } label: { Label("Clear Finished", systemImage: "eraser").toolbarIcon() }
                .help("Remove the files that have been converted (or failed or were stopped) from the list")
                // Only once some file has been through a conversion (done, failed, skipped or
                // stopped): before that there is nothing to tidy away.
                .disabled(!converter.jobs.contains(where: \.isFinished))
            if converter.isRunning {
                Button { converter.stop() } label: { Label("Stop", systemImage: "stop.fill").toolbarIcon() }
                    .help("Stop converting (⌘.)")
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button { convertAll() } label: { Label("Convert All", systemImage: "play.fill").toolbarIcon() }
                    .help("Convert every group with its own template (⌘↩)")
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canStart)
            }
        }
    }

    /// Every group with its own template.
    private func convertAll() {
        for k in [MediaKind.video, .audio, .image] {
            guard let t = model.draft(k) else { continue }
            converter.enqueue(converter.jobs.filter { $0.kind == k }, t)
        }
    }

    private var canStart: Bool {
        converter.jobs.contains { j in j.kind.map { model.draft($0) != nil } == true && Converter.startable(j) }
    }

    /// Video, audio, images, then files that are none of those, each in the order they were added.
    private var groups: [FileGroup] {
        var out = [MediaKind.video, .audio, .image].compactMap { k -> FileGroup? in
            let list = converter.jobs.filter { $0.kind == k }
            return list.isEmpty ? nil : FileGroup(kind: k, jobs: list)
        }
        let other = converter.jobs.filter { $0.kind == nil }
        if !other.isEmpty { out.append(FileGroup(kind: nil, jobs: other)) }
        return out
    }
}

struct FileGroup {
    let kind: MediaKind?
    let jobs: [Job]
    var id: String { kind?.rawValue ?? "other" }
    var title: String {
        switch kind {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Images"
        case nil: "Other"
        }
    }
}

@MainActor
enum MainActions {
    static func openPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowedContentTypes = [.audiovisualContent, .audio, .movie, .image, .folder, .data]
        p.message = "Choose files or folders to convert"
        p.prompt = "Add"
        if p.runModal() == .OK { Converter.shared.add(p.urls) }
    }
}

// MARK: - Empty window

struct DropZone: View {
    var targeted: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 48, weight: .light))
                .tone(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            Text("Drop files to convert")
                .font(.title2.weight(.semibold))
            Text("Audio, video and images, or whole folders. Each kind gets its own group and template. You can also use + or drop files on the Dock icon.")
                .multilineTextAlignment(.center)
                .tone(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            if !Tools.missing.isEmpty {
                Label("Missing tools: \(Tools.missing.joined(separator: ", ")). Rebuild the app with scripts/build-app.sh.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Shown only while files are dragged over the window.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .padding(Layout.gutter)
                .opacity(targeted ? 1 : 0)
        }
        .animation(.smooth(duration: 0.2), value: targeted)
    }
}

// MARK: - Group

/// One kind of file: its template, its files, and a button to convert just these.
struct GroupCard: View {
    let group: FileGroup
    @Environment(AppModel.self) private var model
    @State private var converter = Converter.shared
    @State private var showAdvanced = false
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        Card {
            header
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(group.jobs.enumerated()), id: \.element.id) { i, job in
                    if i > 0 { Divider().padding(.leading, 40) }
                    JobRow(job: job)
                }
            }
        }
        .onAppear {
            // Development aid: MORPHIT_SNAPSHOT_ADVANCED=video|audio|image opens that group's settings.
            if ProcessInfo.processInfo.environment["MORPHIT_SNAPSHOT_ADVANCED"] == group.kind?.rawValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showAdvanced = true }
            }
        }
        .alert("New Template", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let k = group.kind, !newName.trimmingCharacters(in: .whitespaces).isEmpty { model.saveAsNew(k, name: newName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves these settings as a template you can pick again later.")
        }
    }

    @ViewBuilder private var header: some View {
        Label(group.title, systemImage: group.kind?.symbol ?? "questionmark.square.dashed")
            .font(.headline)
            .fixedSize()
        if let k = group.kind {
            TemplateMenu(group: k)
            if model.isModified(k) {
                Text("Modified").font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .tone(.secondary)
            }
            Spacer(minLength: 6)
            Text(status).font(.callout).monospacedDigit().tone(.secondary).lineLimit(1)
            Button { showAdvanced.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
                .help(model.draft(k).map { "Settings for this group: \($0.summary)" } ?? "Settings for this group")
                .disabled(model.draft(k) == nil)
                .popover(isPresented: $showAdvanced, arrowEdge: .bottom) { advanced(k) }
            // X on the left, Play on the right.
            clearGroupButton
            if let d = model.draft(k) {
                Button { converter.enqueue(group.jobs, d) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                    .help("Convert these files to \(d.name)")
                    .disabled(!group.jobs.contains(where: Converter.startable))
            }
        } else {
            Spacer(minLength: 6)
            Text("Not audio, video or images").font(.callout).tone(.secondary)
            clearGroupButton
        }
    }

    private var clearGroupButton: some View {
        Button { converter.clear(group.jobs) } label: { Image(systemName: "xmark.circle") }
            .buttonStyle(.borderless)
            .help("Remove these files from the list")
    }

    @ViewBuilder private func advanced(_ k: MediaKind) -> some View {
        if let binding = model.binding(k) {
            VStack(spacing: 0) {
                HStack {
                    let t = binding.wrappedValue
                    Text(t.name == t.format.title ? t.name : "\(t.name) · \(t.format.title)").font(.headline)
                    Spacer()
                    Menu("Save") {
                        Button("Save to “\(model.saved(k)?.name ?? binding.wrappedValue.name)”") { model.saveToTemplate(k) }
                        Button("Save as New Template…") {
                            newName = TemplateStore.shared.uniqueName(binding.wrappedValue.name)
                            showAdvanced = false
                            naming = true
                        }
                        Divider()
                        Button("Revert to Template") { model.revert(k) }
                    }
                    .fixedSize()
                    .disabled(!model.isModified(k))
                }
                .padding(.horizontal, 16).padding(.top, 12)
                Form {
                    ParameterForm(t: binding, collapsible: true)
                }
                .formStyle(.grouped)
            }
            .frame(width: 420, height: 400)
        }
    }

    private var status: String {
        let n = group.jobs.count
        let done = group.jobs.filter { if case .done = $0.status { true } else { false } }.count
        let failed = group.jobs.filter { if case .failed = $0.status { true } else { false } }.count
        return ["\(n) \(n == 1 ? "file" : "files")", done > 0 ? "\(done) converted" : nil, failed > 0 ? "\(failed) failed" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// The group's template menu: only templates its files can become.
struct TemplateMenu: View {
    let group: MediaKind
    @Environment(AppModel.self) private var model
    @State private var store = TemplateStore.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            ForEach(AppModel.kinds(for: group)) { kind in
                let list = store.templates.filter { $0.format.kind == kind }
                if !list.isEmpty {
                    Section(group == .video && kind == .audio ? "Audio (extract the sound)" : kind.title) {
                        ForEach(list) { t in
                            Button { model.select(t, for: group) } label: {
                                if t.id == model.draft(group)?.id { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Edit Templates…") { SettingsTab.requested = .templates; openSettings() }
        } label: {
            Text(model.draft(group)?.name ?? "No template")
        }
        .controlSize(.small)
        .fixedSize()
        .help("Conversion template for these files")
    }
}

// MARK: - File row

struct JobRow: View {
    let job: Job
    @State private var converter = Converter.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: job.url.path))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                subtitle
                    .font(.caption)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }.disabled(job.trashed)
            if case .done(let out) = job.status {
                Button("Show Converted File") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            }
            Divider()
            Button("Remove from List") { converter.remove(job) }.disabled(job.isActive)
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch job.status {
        case .failed(let msg):
            Text(msg).foregroundStyle(.red)
        case .skipped(let msg):
            Text(msg).foregroundStyle(.secondary)
        case .done(let out):
            Text(([out.lastPathComponent] + (job.trashed ? ["original moved to the Trash"] : []) + (job.note.map { [$0] } ?? []))
                .joined(separator: " · "))
                .foregroundStyle(.secondary)
        default:
            Text([job.detail.isEmpty ? (job.kind?.title ?? "Reading…") : job.detail, job.note].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch job.status {
        case .ready:
            removeButton
        case .waiting:
            Text("Waiting").font(.caption).foregroundStyle(.secondary)
        case .running(let f):
            if let f {
                ProgressView(value: f).frame(width: 110)
            } else {
                ProgressView().controlSize(.small)
            }
        case .done(let out):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Button { NSWorkspace.shared.activateFileViewerSelecting([out]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Show in Finder")
                removeButton
            }
        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                removeButton
            }
        case .skipped:
            HStack(spacing: 6) {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                removeButton
            }
        case .cancelled:
            HStack(spacing: 6) {
                Text("Stopped").font(.caption).foregroundStyle(.secondary)
                removeButton
            }
        }
    }

    private var removeButton: some View {
        Button { converter.remove(job) } label: { Image(systemName: "xmark") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove from the list")
    }
}

// MARK: - Footer

/// Status bar, as in the other apps: what is in the list and how far the conversion is.
struct Footer: View {
    @State private var converter = Converter.shared
    @AppStorage("outputFolder") private var outputFolder: String = ""
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                status.layoutPriority(-1)
                if !converter.undoable.isEmpty {
                    UndoButton { withAnimation(.smooth(duration: 0.3)) { converter.undoLast() } }
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .opacity))
                }
                Spacer(minLength: 8)
                Label(outputFolder.isEmpty ? "Next to originals" : URL(fileURLWithPath: outputFolder).lastPathComponent, systemImage: "folder")
                    .help("Converted files go \(outputFolder.isEmpty ? "next to the originals" : "to " + outputFolder)")
            }
            .font(.callout)
            .tone(.secondary)
            .padding(.horizontal, 12)
            .frame(height: Layout.footerHeight - 1)
            .clipped()
            // Undo rises in once the conversion has ended.
            .animation(.smooth(duration: 0.35).delay(0.15), value: converter.undoable.isEmpty)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var status: some View {
        let total = converter.jobs.count
        if converter.isRunning {
            HStack(spacing: 10) {
                ProgressView(value: converter.overallProgress).frame(width: 120).controlSize(.small)
                Text("\(converter.finishedCount) of \(converter.jobs.filter { $0.status != .ready }.count) converted")
                    .monospacedDigit()
            }
        } else if total == 0 {
            Text("No files")
        } else {
            let done = converter.doneCount, failed = converter.failedCount
            Text([
                "\(total) \(total == 1 ? "file" : "files")",
                done > 0 ? "\(done) converted" : nil,
                failed > 0 ? "\(failed) failed" : nil,
            ].compactMap { $0 }.joined(separator: " · "))
        }
    }
}

/// Small capsule button in the status bar that undoes the last conversion.
struct UndoButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label("Undo", systemImage: "arrow.uturn.backward")
                .font(.callout)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(hover ? 0.12 : 0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .tone(.primary)
        .onHover { hover = $0 }
        .help("Undo the conversion: delete the new files and put the originals back")
    }
}

/// The title bar icon: turns clockwise while converting, speeding up at the start (ease-in) and
/// slowing down to rest upright at the end (ease-out).
struct SpinningIcon: View {
    let running: Bool
    @State private var spin = Spin()
    @State private var active = false

    var body: some View {
        TimelineView(.animation(paused: !active)) { ctx in
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 17))
                .rotationEffect(.degrees(spin.step(ctx.date) {
                    DispatchQueue.main.async { if !running { active = false } }
                }))
        }
        .frame(width: 22)
        .onChange(of: running, initial: true) {
            spin.running = running
            if running { if !active { spin.last = nil }; active = true }
        }
    }

    /// Angle and speed, advanced on each frame (not observed: the timeline redraws).
    final class Spin {
        var running = false
        var last: Date?
        private var angle = 0.0          // degrees, clockwise
        private var speed = 0.0          // degrees per second
        private let top = 300.0          // a turn in 1.2 s
        private let accel = 500.0        // full speed in 0.6 s
        /// The slow-down: from `from`, `distance` degrees in `duration` seconds, easing out.
        private var brake: (start: Date, from: Double, distance: Double, duration: Double)?

        func step(_ now: Date, rested: () -> Void) -> Double {
            let dt = last.map { min(max(now.timeIntervalSince($0), 0), 0.05) } ?? 0
            last = now
            if running {
                brake = nil
                speed = min(top, speed + accel * dt)
                angle += speed * dt
                if angle >= 360 { angle -= 360 }
            } else if speed > 0 || brake != nil {
                if brake == nil {
                    // Stops upright on a half turn (the two arrows look the same every 180°), in
                    // 0.4–0.9 s whatever the speed, starting at about the speed it had.
                    let stop = ((angle + max(speed, 60) * 0.3) / 180).rounded(.up) * 180
                    let d = stop - angle
                    brake = (now, angle, d, min(max(2 * d / max(speed, 1), 0.4), 0.9))
                }
                let b = brake!
                let u = min(now.timeIntervalSince(b.start) / b.duration, 1)
                angle = b.from + b.distance * (1 - (1 - u) * (1 - u))
                speed = 2 * b.distance / b.duration * (1 - u)
                if u >= 1 {
                    angle = (b.from + b.distance).truncatingRemainder(dividingBy: 360)   // 0 or 180: same look
                    speed = 0; brake = nil
                    rested()
                }
            } else {
                rested()
            }
            return angle
        }
    }
}
