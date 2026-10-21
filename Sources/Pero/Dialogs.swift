import AppKit

/// Small sheets: a name, the notes password, a link, progress.
enum TextPrompt {
    static func ask(on window: NSWindow, title: String, message: String, value: String, confirm: String,
                    done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Отменить")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { done(field.stringValue) }
        }
    }
}

enum PasswordSheet {
    /// First lock: create the password for locked notes, with a hint (as in Notes).
    static func create(on window: NSWindow, done: @escaping (String, String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Создайте пароль для заблокированных заметок"
        alert.informativeText = "Им открываются все заблокированные заметки. Если забыть пароль и Touch ID недоступен, прочитать их будет нельзя."
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 58, width: 280, height: 24))
        password.placeholderString = "Пароль"
        let repeatField = NSSecureTextField(frame: NSRect(x: 0, y: 29, width: 280, height: 24))
        repeatField.placeholderString = "Подтверждение"
        let hint = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        hint.placeholderString = "Подсказка (рекомендуется)"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 82))
        [password, repeatField, hint].forEach(box.addSubview)
        alert.accessoryView = box
        alert.addButton(withTitle: "Задать пароль")
        alert.addButton(withTitle: "Отменить")
        alert.window.initialFirstResponder = password
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            guard !password.stringValue.isEmpty, password.stringValue == repeatField.stringValue else {
                let error = NSAlert()
                error.messageText = password.stringValue.isEmpty ? "Пароль не может быть пустым" : "Пароли не совпадают"
                error.beginSheetModal(for: window) { _ in create(on: window, done: done) }
                return
            }
            done(password.stringValue, hint.stringValue.isEmpty ? nil : hint.stringValue)
        }
    }

    /// The password, asked again until it is right or the user gives up.
    static func enter(on window: NSWindow, hint: String?, check: @escaping (String) -> Bool) {
        let alert = NSAlert()
        alert.messageText = "Введите пароль для заблокированных заметок"
        alert.informativeText = hint.map { "Подсказка: \($0)" } ?? ""
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Отменить")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            if !check(field.stringValue) {
                DispatchQueue.main.async { enter(on: window, hint: hint, check: check) }
            }
        }
    }

    static func change(on window: NSWindow, done: @escaping (String, String, String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Изменить пароль для заблокированных заметок"
        let old = NSSecureTextField(frame: NSRect(x: 0, y: 87, width: 280, height: 24))
        old.placeholderString = "Старый пароль"
        let new = NSSecureTextField(frame: NSRect(x: 0, y: 58, width: 280, height: 24))
        new.placeholderString = "Новый пароль"
        let repeatField = NSSecureTextField(frame: NSRect(x: 0, y: 29, width: 280, height: 24))
        repeatField.placeholderString = "Подтверждение"
        let hint = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        hint.placeholderString = "Подсказка"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 111))
        [old, new, repeatField, hint].forEach(box.addSubview)
        alert.accessoryView = box
        alert.addButton(withTitle: "Изменить")
        alert.addButton(withTitle: "Отменить")
        alert.window.initialFirstResponder = old
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, !new.stringValue.isEmpty, new.stringValue == repeatField.stringValue else { return }
            done(old.stringValue, new.stringValue, hint.stringValue.isEmpty ? nil : hint.stringValue)
        }
    }
}

/// ⌘K: «Добавить ссылку» with the text and the address.
enum LinkSheet {
    static func present(on window: NSWindow, text: String, url: String, done: @escaping (String, String) -> Void) {
        let alert = NSAlert()
        alert.messageText = url.isEmpty ? "Добавить ссылку" : "Изменить ссылку"
        let textField = NSTextField(frame: NSRect(x: 64, y: 30, width: 260, height: 24))
        textField.stringValue = text
        textField.placeholderString = "Текст ссылки"
        let urlField = NSTextField(frame: NSRect(x: 64, y: 0, width: 260, height: 24))
        urlField.stringValue = url
        urlField.placeholderString = "https://… или [[Заметка]]"
        let l1 = NSTextField(labelWithString: "Текст:")
        l1.frame = NSRect(x: 0, y: 33, width: 60, height: 18)
        let l2 = NSTextField(labelWithString: "Адрес:")
        l2.frame = NSRect(x: 0, y: 3, width: 60, height: 18)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 324, height: 56))
        [l1, textField, l2, urlField].forEach(box.addSubview)
        alert.accessoryView = box
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Отменить")
        alert.window.initialFirstResponder = url.isEmpty && !text.isEmpty ? urlField : textField
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            var address = urlField.stringValue.trimmingCharacters(in: .whitespaces)
            if address.lowercased().hasPrefix("www.") { address = "https://" + address }
            done(textField.stringValue, address)
        }
    }
}

final class ProgressSheet {
    private let panel: NSPanel
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private weak var parent: NSWindow?

    private init(parent: NSWindow, title: String) {
        self.parent = parent
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 96), styleMask: [.titled], backing: .buffered, defer: false)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 13)
        bar.isIndeterminate = true
        bar.style = .bar
        bar.startAnimation(nil)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [titleLabel, bar, label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 320).isActive = true
        panel.contentView = stack
    }

    static func show(on window: NSWindow, title: String) -> ProgressSheet {
        let sheet = ProgressSheet(parent: window, title: title)
        window.beginSheet(sheet.panel)
        return sheet
    }

    func update(_ done: Int, _ total: Int) {
        guard total > 0 else { return }
        bar.isIndeterminate = false
        bar.maxValue = Double(total)
        bar.doubleValue = Double(done)
        label.stringValue = "\(done) из \(total)"
    }

    func close() { parent?.endSheet(panel) }
}
