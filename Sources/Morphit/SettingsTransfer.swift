import AppKit
import Foundation
import UniformTypeIdentifiers

/// Export and import of the settings and templates, as one JSON file ("Morphit Settings.json").
struct SettingsBackup: Codable {
    var app = "Morphit"
    var version = 1
    var cpuLevel: CPULevel?
    var outputFolder: String?        // "" = next to the originals
    var trashOriginals: Bool?
    var templates: [ConversionTemplate]

    @MainActor static func current() -> SettingsBackup {
        SettingsBackup(cpuLevel: Prefs.cpu, outputFolder: Prefs.outputFolder?.path ?? "",
                       trashOriginals: Prefs.trashOriginals, templates: TemplateStore.shared.templates)
    }

    static func read(_ url: URL) throws -> SettingsBackup {
        let data = try Data(contentsOf: url)
        guard let b = try? JSONDecoder().decode(SettingsBackup.self, from: data), b.app == "Morphit" else {
            throw ToolError(message: "“\(url.lastPathComponent)” isn’t a Morphit settings file.")
        }
        return b
    }

    func write(_ url: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// Applies the general settings; the templates replace the current ones or are added to them
    /// (a name already in use gets a number).
    @MainActor func apply(replacingTemplates: Bool) {
        if let c = cpuLevel { Prefs.cpu = c }
        if let f = outputFolder { Prefs.outputFolder = f.isEmpty ? nil : URL(fileURLWithPath: f) }
        if let t = trashOriginals { Prefs.trashOriginals = t }
        let store = TemplateStore.shared
        if replacingTemplates, !templates.isEmpty {
            store.templates = templates
        } else {
            for t in templates { store.add(t) }
        }
    }
}

@MainActor
enum SettingsTransfer {
    static func export() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.json]
        p.nameFieldStringValue = "Morphit Settings.json"
        p.message = "Export Morphit’s settings and templates"
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try SettingsBackup.current().write(url) } catch { alert("Couldn’t export the settings", error.localizedDescription) }
    }

    static func importFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.message = "Choose a Morphit settings file"
        p.prompt = "Import"
        guard p.runModal() == .OK, let url = p.url else { return }
        let backup: SettingsBackup
        do { backup = try SettingsBackup.read(url) } catch { alert("Couldn’t import the settings", error.localizedDescription); return }
        let a = NSAlert()
        let n = backup.templates.count
        a.messageText = "Import “\(url.deletingPathExtension().lastPathComponent)”?"
        a.informativeText = "The general settings are replaced. The file has \(n) \(n == 1 ? "template" : "templates"): they can replace your templates, or be added to them."
        a.addButton(withTitle: "Replace Templates")
        a.addButton(withTitle: "Add Templates")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: backup.apply(replacingTemplates: true)
        case .alertSecondButtonReturn: backup.apply(replacingTemplates: false)
        default: return
        }
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
