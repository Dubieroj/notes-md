import AppKit
import PeroKit

/// The editor column: the shared editor page, or a placeholder, or the lock screen of a
/// locked note.
final class NoteEditorController: NSViewController {
    let editor: EditorViewController
    private let placeholder = NSTextField(labelWithString: "")
    let lockView = LockedNoteView()

    enum Display {
        case nothing(String)
        case session(NoteSession)
        case locked(NoteRecord)
    }

    init() {
        editor = EditorViewController(source: nil)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        addChild(editor)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .systemFont(ofSize: 16)
        placeholder.alignment = .center
        for v in [editor.view, placeholder, lockView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            editor.view.topAnchor.constraint(equalTo: root.topAnchor),
            editor.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            editor.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editor.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            lockView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            lockView.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -40),
            lockView.widthAnchor.constraint(equalToConstant: 300),
        ])
        view = root
        display(.nothing(""))
    }

    func display(_ d: Display, focus: Bool = false) {
        switch d {
        case .nothing(let text):
            editor.show(nil)
            editor.view.isHidden = true
            lockView.isHidden = true
            placeholder.isHidden = false
            placeholder.stringValue = text
        case .session(let session):
            placeholder.isHidden = true
            lockView.isHidden = true
            editor.view.isHidden = false
            editor.show(session, focus: focus)
        case .locked(let record):
            editor.show(nil)
            editor.view.isHidden = true
            placeholder.isHidden = true
            lockView.isHidden = false
            lockView.prepare(title: record.displayTitle)
            view.window?.makeFirstResponder(lockView.password)
        }
    }
}

/// «Эта заметка заблокирована»: password, hint, Touch ID.
final class LockedNoteView: NSStackView {
    let password = NSSecureTextField()
    private let title = NSTextField(labelWithString: "Эта заметка заблокирована.")
    private let subtitle = NSTextField(labelWithString: "Введите пароль для заметок, чтобы открыть её.")
    private let hint = NSTextField(labelWithString: "")
    private let touchID = NSButton()
    private let hintButton = NSButton(title: "Подсказка", target: nil, action: nil)

    var onPassword: (String) -> Void = { _ in }
    var onTouchID: () -> Void = {}
    var hintText: () -> String? = { nil }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 10
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 34, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        password.placeholderString = "Пароль"
        password.target = self
        password.action = #selector(submit)
        password.widthAnchor.constraint(equalToConstant: 220).isActive = true
        hint.textColor = .secondaryLabelColor
        hint.isHidden = true
        touchID.title = "Использовать Touch ID"
        touchID.image = NSImage(systemSymbolName: "touchid", accessibilityDescription: nil)
        touchID.imagePosition = .imageLeading
        touchID.bezelStyle = .rounded
        touchID.target = self
        touchID.action = #selector(touch)
        hintButton.bezelStyle = .inline
        hintButton.target = self
        hintButton.action = #selector(showHint)
        for v in [icon, title, subtitle, password, touchID, hintButton, hint] { addArrangedSubview(v) }
        setCustomSpacing(16, after: subtitle)
    }

    required init?(coder: NSCoder) { fatalError() }

    func prepare(title noteTitle: String) {
        password.stringValue = ""
        hint.isHidden = true
        touchID.isHidden = !(Settings.useTouchID && LockManager.canUseBiometrics)
        hintButton.isHidden = hintText() == nil
        setAccessibilityLabel("Заметка «\(noteTitle)» заблокирована")
    }

    func shake() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -8, 8, -6, 6, -3, 3, 0]
        animation.duration = 0.35
        password.wantsLayer = true
        password.layer?.add(animation, forKey: "shake")
        password.stringValue = ""
    }

    @objc private func submit() { onPassword(password.stringValue) }
    @objc private func touch() { onTouchID() }
    @objc private func showHint() {
        hint.stringValue = "Подсказка: " + (hintText() ?? "")
        hint.isHidden = false
    }
}
