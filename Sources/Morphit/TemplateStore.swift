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
        if let data = try? Data(contentsOf: Self.file), let list = try? JSONDecoder().decode([ConversionTemplate].self, from: data), !list.isEmpty {
            templates = list
        } else {
            templates = ConversionTemplate.builtIn
        }
    }

    private func save() {
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

    func delete(_ t: ConversionTemplate) {
        templates.removeAll { $0.id == t.id }
        if templates.isEmpty { templates = ConversionTemplate.builtIn }
    }

    func restoreDefaults() {
        // Adds back the built-in templates that are missing (by name); user templates stay.
        let names = Set(templates.map(\.name))
        for t in ConversionTemplate.builtIn where !names.contains(t.name) { add(t) }
    }

    func uniqueName(_ name: String) -> String {
        let names = Set(templates.map(\.name))
        guard names.contains(name) else { return name }
        var n = 2
        while names.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }

    var selectedID: UUID? {
        get { UserDefaults.standard.string(forKey: "selectedTemplate").flatMap(UUID.init) }
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
