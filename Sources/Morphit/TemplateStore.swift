import AppKit
import Foundation
import Observation
import UserNotifications

/// The conversion templates, saved in ~/Library/Application Support/Morphit/templates.json.
@MainActor @Observable
final class TemplateStore {
    static let shared = TemplateStore()

    var templates: [ConversionTemplate] { didSet { save() } }

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Morphit")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("templates.json")
    }

    private init() {
        if var data = try? Data(contentsOf: Self.file) {
            // The old built-in "HEVC" template (format "HEVC (MP4)", no longer offered: MP4 holds
            // HEVC) goes, if it was never changed. A changed one becomes MP4 with HEVC.
            if var raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                raw.removeAll { ($0["format"] as? String) == "hevc" && ($0["name"] as? String) == "HEVC"
                    && (($0["video"] as? [String: Any]).map { ($0["quality"] as? String ?? "source") == "source" && $0["codec"] == nil && $0["resolution"] == nil } ?? true) }
                if let d = try? JSONSerialization.data(withJSONObject: raw) { data = d }
            }
            templates = (try? JSONDecoder().decode([ConversionTemplate].self, from: data)) ?? ConversionTemplate.builtIn
        } else {
            templates = ConversionTemplate.builtIn
        }
        // Development aid with MORPHIT_SNAPSHOT: MORPHIT_DEMO_TEMPLATE='<template JSON>' shows that
        // template first and selected, and nothing is saved.
        if let json = ProcessInfo.processInfo.environment["MORPHIT_DEMO_TEMPLATE"],
           let t = try? JSONDecoder().decode(ConversionTemplate.self, from: Data(json.utf8)) {
            Self.demo = t.id
            templates.insert(t, at: 0)
        }
    }

    private static var demo: UUID?

    private func save() {
        guard Self.demo == nil else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(templates) { try? data.write(to: Self.file, options: .atomic) }
    }

    func template(_ id: UUID?) -> ConversionTemplate? { templates.first { $0.id == id } }

    func update(_ t: ConversionTemplate) {
        if let i = templates.firstIndex(where: { $0.id == t.id }) { templates[i] = t }
    }

    @discardableResult
    func add(_ t: ConversionTemplate) -> ConversionTemplate {
        var t = t
        t.id = UUID()
        t.name = uniqueName(t.name)
        // Next to the others of its kind.
        if let last = templates.lastIndex(where: { $0.format.kind == t.format.kind }) {
            templates.insert(t, at: last + 1)
        } else {
            templates.append(t)
        }
        return t
    }

    @discardableResult
    func duplicate(_ t: ConversionTemplate) -> ConversionTemplate {
        var copy = t
        copy.name = t.name + " copy"
        copy.id = UUID()
        copy.name = uniqueName(copy.name)
        if let i = templates.firstIndex(where: { $0.id == t.id }) { templates.insert(copy, at: i + 1) } else { templates.append(copy) }
        return copy
    }

    /// Removes any template, built-in ones included. With an undo manager, ⌘Z puts it back in
    /// the same place (and ⇧⌘Z removes it again).
    func delete(_ t: ConversionTemplate, undoManager: UndoManager? = nil) {
        guard let i = templates.firstIndex(where: { $0.id == t.id }) else { return }
        templates.remove(at: i)
        undoManager?.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.restore(t, at: i, undoManager: undoManager) }
        }
        undoManager?.setActionName("Delete Template")
    }

    private func restore(_ t: ConversionTemplate, at i: Int, undoManager: UndoManager?) {
        templates.insert(t, at: min(i, templates.count))
        undoManager?.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.delete(t, undoManager: undoManager) }
        }
        undoManager?.setActionName("Delete Template")
        NotificationCenter.default.post(name: .templateRestored, object: t.id)
    }

    func uniqueName(_ name: String) -> String {
        let names = Set(templates.map(\.name))
        guard names.contains(name) else { return name }
        var n = 2
        while names.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }

    var selectedID: UUID? {
        get { Self.demo ?? UserDefaults.standard.string(forKey: "selectedTemplate").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "selectedTemplate") }
    }
}

/// A banner when a batch ends while Morphit is in the background. Permission is asked the first
/// time a conversion starts.
@MainActor
enum Notifier {
    static func prepare() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil, NSApp != nil, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension Notification.Name {
    /// A deleted template came back (undo): Settings selects it.
    static let templateRestored = Notification.Name("MorphitTemplateRestored")
}
