import AppKit
import PeroKit
import SwiftUI

/// Перо ▸ Настройки (⌘,): Notes's settings plus Перо's own.
final class SettingsWindowController: NSWindowController {
    static var shared: SettingsWindowController?

    static func show(library: Library, lock: LockManager) {
        if shared == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Настройки"
            window.contentViewController = NSHostingController(rootView: SettingsView(library: library, lock: lock))
            window.center()
            shared = SettingsWindowController(window: window)
        }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    /// The library moved: the next opening shows the new one.
    static func reset() {
        shared?.close()
        shared = nil
    }
}

private struct SettingsView: View {
    let library: Library
    let lock: LockManager
    @State private var sortKey = Settings.sortKey
    @State private var groupByDate = Settings.groupByDate
    @State private var newNoteStyle = Settings.newNoteStyle
    @State private var autoSort = Settings.autoSortChecked
    @State private var resumeQuick = Settings.resumeLastQuickNote
    @State private var zoom = Settings.zoom
    @State private var touchID = Settings.useTouchID
    @State private var autoLock = Settings.autoLockMinutes
    @State private var shortcut = Settings.quickNoteShortcut
    @State private var badge = Settings.showDockBadge
    @State private var wordCount = Settings.showWordCount
    @State private var writingTools = Settings.writingTools
    @State private var backupInterval = Settings.backupInterval
    @State private var hasPassword = false
    @State private var linked = Settings.linkedFolders
    @State private var opensMarkdown = FileTypes.peroOpensMarkdown

    var body: some View {
        Form {
            Section("Заметки") {
                Picker("Сортировать заметки по", selection: $sortKey) {
                    Text("Дата изменения").tag(SortKey.modified)
                    Text("Дата создания").tag(SortKey.created)
                    Text("Название").tag(SortKey.title)
                }
                .onChange(of: sortKey) { _, value in Settings.sortKey = value; Settings.sortAscending = value == .title }
                Toggle("Группировать заметки по дате", isOn: $groupByDate)
                    .onChange(of: groupByDate) { _, value in Settings.groupByDate = value }
                Picker("Новые заметки начинаются с", selection: $newNoteStyle) {
                    Text("Названия").tag("h1")
                    Text("Заголовка").tag("h2")
                    Text("Подзаголовка").tag("h3")
                    Text("Основного текста").tag("body")
                }
                .onChange(of: newNoteStyle) { _, value in Settings.newNoteStyle = value }
                Toggle("Автоматически сортировать отмеченные пункты", isOn: $autoSort)
                    .onChange(of: autoSort) { _, value in Settings.autoSortChecked = value }
                Toggle("Всегда продолжать последнюю быструю заметку", isOn: $resumeQuick)
                    .onChange(of: resumeQuick) { _, value in Settings.resumeLastQuickNote = value }
                HStack {
                    Text("Размер текста по умолчанию")
                    Slider(value: $zoom, in: 0.7...1.8, step: 0.1) { Text("") }
                        .onChange(of: zoom) { _, value in Settings.zoom = value }
                    Text("\(Int(zoom * 100)) %").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            Section("Заблокированные заметки") {
                if hasPassword {
                    Button("Изменить пароль…") { changePassword() }
                } else {
                    Text("Пароль задаётся при первой блокировке заметки.").foregroundStyle(.secondary)
                }
                Toggle("Использовать Touch ID", isOn: $touchID)
                    .onChange(of: touchID) { _, on in
                        Settings.useTouchID = on
                        if !on { Keychain.remove(for: library.root) }
                    }
                    .disabled(!LockManager.canUseBiometrics)
                Picker("Закрывать после бездействия", selection: $autoLock) {
                    Text("1 минуты").tag(1)
                    Text("5 минут").tag(5)
                    Text("15 минут").tag(15)
                    Text("1 часа").tag(60)
                }
                .onChange(of: autoLock) { _, value in Settings.autoLockMinutes = value }
            }
            Section("Заметки.md") {
                LabeledContent("Библиотека") {
                    HStack {
                        Text(library.root.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Показать") { NSWorkspace.shared.activateFileViewerSelecting([library.root]) }
                    }
                }
                Button("Выбрать другую папку для библиотеки…") {
                    (NSApp.delegate as? AppDelegate)?.chooseLibraryFolder()
                }
                LabeledContent("Файлы Markdown") {
                    if opensMarkdown {
                        Text("открываются в Заметках.md").foregroundStyle(.secondary)
                    } else {
                        Button("Открывать в Заметках.md") { makeDefault() }
                    }
                }
                Toggle("Быстрая заметка по ⌃⌥⌘N из любого приложения", isOn: $shortcut)
                    .onChange(of: shortcut) { _, value in Settings.quickNoteShortcut = value }
                Toggle("Число быстрых заметок на значке в Dock", isOn: $badge)
                    .onChange(of: badge) { _, value in Settings.showDockBadge = value }
                Toggle("Счётчик слов и время чтения внизу заметки", isOn: $wordCount)
                    .onChange(of: wordCount) { _, value in Settings.showWordCount = value }
                Toggle("Writing Tools (Apple Intelligence) в заметках", isOn: $writingTools)
                    .onChange(of: writingTools) { _, value in Settings.writingTools = value }
                Picker("Резервная копия в iCloud Drive", selection: $backupInterval) {
                    Text("Выкл.").tag(0)
                    Text("Каждый день").tag(1)
                    Text("Каждую неделю").tag(7)
                }
                .onChange(of: backupInterval) { _, value in Settings.backupInterval = value }
                Button("Сделать резервную копию сейчас") { Backup.run(library: library, interactive: true) }
            }
            Section("Папки на диске") {
                if linked.isEmpty {
                    Text("Любую папку с Markdown-файлами можно показать в боковой панели: файлы правятся там, где лежат.")
                        .foregroundStyle(.secondary)
                }
                ForEach(linked, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Отключить") { unlink(path) }
                    }
                }
                Button("Подключить папку…") { link() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
        .onAppear { hasPassword = lock.hasPassword }
    }

    private func changePassword() {
        guard let window = SettingsWindowController.shared?.window else { return }
        PasswordSheet.change(on: window) { old, new, hint in
            do { try lock.changePassword(from: old, to: new, hint: hint) } catch {
                let alert = NSAlert()
                alert.messageText = "Старый пароль неверный"
                alert.beginSheetModal(for: window)
            }
        }
    }

    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    private func link() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Подключить"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appDelegate?.main?.link(url)
        linked = Settings.linkedFolders
    }

    private func makeDefault() {
        Task {
            do { try await FileTypes.openMarkdownInPero() } catch { NSApp.presentError(error) }
            opensMarkdown = FileTypes.peroOpensMarkdown
        }
    }

    private func unlink(_ path: String) {
        guard let library = appDelegate?.libraries?.library(withRoot: path) else { return }
        appDelegate?.main?.unlink(library)
        linked = Settings.linkedFolders
    }
}

/// «Резервная копия в iCloud Drive»: a zip of the library, the last ten kept.
enum Backup {
    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Заметки.md — резервные копии")
    }

    static func runIfDue(library: Library) {
        let days = Settings.backupInterval
        guard days > 0 else { return }
        if let last = Settings.lastBackup, Date().timeIntervalSince(last) < Double(days) * 86400 { return }
        run(library: library, interactive: false)
    }

    static func run(library: Library, interactive: Bool) {
        let folder = Settings.backupFolder ?? defaultFolder
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH-mm"
        let target = folder.appendingPathComponent("Заметки \(stamp.string(from: Date())).zip")
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--keepParent", "--norsrc", library.root.path, target.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                // Keep the ten newest copies.
                let copies = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]))?
                    .filter { $0.lastPathComponent.hasPrefix("Заметки ") && $0.pathExtension == "zip" }
                    .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
                for old in copies.dropFirst(10) { try? FileManager.default.removeItem(at: old) }
                DispatchQueue.main.async {
                    Settings.lastBackup = Date()
                    if interactive { NSWorkspace.shared.activateFileViewerSelecting([target]) }
                }
            } catch {
                DispatchQueue.main.async { if interactive { NSAlert(error: error).runModal() } }
            }
        }
    }
}
