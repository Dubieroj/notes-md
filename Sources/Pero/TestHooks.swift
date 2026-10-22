import AppKit
import PeroKit

/// Remote control for automated checks (tools/check.sh). Compiled only into the build for
/// checks (PERO_TEST_HOOKS=1 ./run.sh), active only when started with PERO_TEST_DIR set:
/// commands are JSON files `<id>.cmd.json` in that folder, each answer goes to `<id>.out.json`.
#if PERO_TEST_HOOKS
enum TestHooks {
    static func startIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["PERO_TEST_DIR"] else { return }
        let dir = URL(fileURLWithPath: path)
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in poll(dir) }
    }

    private static func poll(_ dir: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasSuffix(".cmd.json") {
            guard let data = try? Data(contentsOf: file),
                  let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            try? FileManager.default.removeItem(at: file)
            let id = file.lastPathComponent.replacingOccurrences(of: ".cmd.json", with: "")
            run(command) { result in
                let answer = ["result": result ?? NSNull()]
                let json = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data(#"{"result":"unencodable"}"#.utf8)
                try? json.write(to: dir.appendingPathComponent(id + ".out.json"), options: .atomic)
            }
        }
    }

    private static func run(_ command: [String: Any], done: @escaping (Any?) -> Void) {
        let docs = NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }
        let real = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        let doc = (command["path"] as? String).flatMap { path in docs.first { $0.fileURL.map { real($0.path) } == real(path) } } ?? docs.first
        let controller = doc?.windowControllers.first as? EditorWindowController
        let window = controller?.window
        let arg = command["arg"] as? String ?? ""

        let delegate = NSApp.delegate as? AppDelegate
        let main = delegate?.main
        switch command["action"] as? String ?? "" {
        case "main":
            guard let main, let library = delegate?.library else { return done(nil) }
            done(["window": main.window?.windowNumber ?? 0, "scope": main.scope.encoded,
                  "library": main.library.root.path, "linked": Settings.linkedFolders,
                  "currentNotes": main.library.notes.keys.sorted(),
                  "selected": main.list.selectedPaths, "session": main.session?.path ?? "",
                  "rows": main.list.rows.map { row -> String in
                      switch row { case .header(let h): return "## " + h; case .note(let r): return r.path }
                  },
                  "notes": library.notes.keys.sorted(), "folders": library.folders,
                  "trash": library.trash.map(\.originalPath), "pinned": library.state.pinned,
                  "tags": library.tagCounts().map(\.tag), "root": library.root.path,
                  "dirty": main.session?.isDirty ?? false])
        case "mainjs":
            guard let main else { return done(nil) }
            main.editor.evaluate(arg) { done($0) }
        case "mainaction":
            guard let main else { return done(false) }
            let item = NSMenuItem()
            item.representedObject = command["represented"]
            done(NSApp.sendAction(Selector(arg), to: main, from: item))
        case "scope":
            guard let main, let scope = Scope(encoded: arg) else { return done(false) }
            let other = (command["root"] as? String).flatMap { delegate?.libraries?.library(withRoot: $0) }
            main.showScope(scope, in: other)
            done(true)
        case "link":
            guard let main else { return done(false) }
            main.link(URL(fileURLWithPath: arg))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { done(main.library.root.path) }
        case "unlink":
            guard let main, let library = delegate?.libraries?.library(withRoot: arg) else { return done(false) }
            main.unlink(library)
            done(true)
        case "switchLibrary":
            delegate?.switchLibrary(to: URL(fileURLWithPath: arg), copyNotes: command["copy"] as? Bool ?? false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { done(delegate?.library?.root.path ?? "") }
        case "reveal":
            main?.reveal(arg)
            done(true)
        case "search":
            main?.testSearch(arg)
            done(true)
        case "mainkey":
            guard let window = main?.window, let code = command["keyCode"] as? Int else { return done(false) }
            var flags: NSEvent.ModifierFlags = []
            for m in command["modifiers"] as? [String] ?? [] {
                switch m {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "option": flags.insert(.option)
                case "control": flags.insert(.control)
                default: break
                }
            }
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: arg, charactersIgnoringModifiers: arg,
                isARepeat: false, keyCode: UInt16(code)) else { return done(false) }
            if flags.contains(.command) {
                if !window.performKeyEquivalent(with: event) { _ = NSApp.mainMenu?.performKeyEquivalent(with: event) }
            } else {
                window.sendEvent(event)
            }
            done(true)
        case "export":
            // export <library path> → arg: destination file; format in "format".
            guard let main, let library = delegate?.library, let path = command["path"] as? String,
                  let record = library.record(path), let format = ExportFormat(rawValue: command["format"] as? String ?? "") else { return done(nil) }
            LibraryExport(library: library, editor: main.editor).export(record, as: format, to: URL(fileURLWithPath: arg)) { error in
                done(error.map { "\($0)" } ?? "ok")
            }
        case "smart":
            // A smart folder from JSON filters, then shown.
            guard let main, let library = delegate?.library, let data = arg.data(using: .utf8),
                  let filters = try? JSONDecoder().decode([SmartFilter].self, from: data) else { return done(nil) }
            let smart = SmartFolder(name: command["name"] as? String ?? "Тест", filters: filters)
            library.addSmartFolder(smart)
            main.showScope(.smart(smart.id))
            done(smart.id)
        case "lockSetup":
            guard let lock = delegate?.lock else { return done(false) }
            if lock.hasPassword { done(lock.unlock(password: arg)) } else { done((try? lock.setPassword(arg, hint: "тест")) != nil) }
        case "lockNow":
            delegate?.lock?.lockNow()
            done(true)
        case "import":
            // import <file or folder> into "folder".
            guard let main, let library = delegate?.library else { return done(nil) }
            Importer(library: library, editor: main.editor)
                .importItems([URL(fileURLWithPath: arg)], into: command["folder"] as? String ?? "", keepStructure: true) { report in
                    library.rescan { done(["notes": report.notes, "skipped": report.skipped, "losses": Array(report.losses)]) }
                }
        case "app":
            // An app-level menu command (settings, quick note…), through the responder chain.
            done(NSApp.sendAction(Selector(arg), to: nil, from: NSMenuItem()))
        case "columns":
            // Moves a divider like a drag ("divider", "position"), then reports the columns.
            guard let main, let split = main.window?.contentViewController as? NSSplitViewController else { return done(nil) }
            if let divider = command["divider"] as? Int, let position = command["position"] as? Double {
                split.splitView.setPosition(CGFloat(position), ofDividerAt: divider)
                split.splitView.adjustSubviews()
            }
            let back = main.window?.toolbar?.items.first { $0.itemIdentifier == LibraryWindowController.backToGalleryID }
            done(["columns": split.splitViewItems.map { ["width": Int($0.viewController.view.frame.width), "collapsed": $0.isCollapsed] },
                  "backButtonVisible": back.map { !$0.isHidden } ?? false])
        case "menus":
            // Top-level menus with their items, to check the interface language.
            done((NSApp.mainMenu?.items ?? []).map { top in
                [top.submenu?.title ?? top.title] + (top.submenu?.items ?? []).filter { !$0.isSeparatorItem }.map(\.title)
            })
        case "allWindows":
            done(NSApp.windows.filter(\.isVisible).map { ["title": $0.title, "window": $0.windowNumber, "class": String(describing: type(of: $0))] })
        case "scrollToEnd":
            // The window titled arg scrolled to its end, for snapshots of long forms (settings).
            func scrollView(in view: NSView) -> NSScrollView? {
                (view as? NSScrollView) ?? view.subviews.lazy.compactMap(scrollView).first
            }
            guard let scroll = NSApp.windows.first(where: { $0.title == arg })?.contentView.flatMap(scrollView),
                  let doc = scroll.documentView else { return done(false) }
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? doc.bounds.height - clip.bounds.height : 0))
            scroll.reflectScrolledClipView(clip)
            done(true)
        case "bench":
            // Timings for the performance checks: search, the «Все заметки» list, one save.
            guard let main, let library = delegate?.library else { return done(nil) }
            func ms(_ times: Int, _ body: () -> Void) -> Double {
                let start = CFAbsoluteTimeGetCurrent()
                for _ in 0..<times { body() }
                return (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(times)
            }
            let search = ms(20) { _ = library.search(arg.isEmpty ? "встреча бюджет" : arg) }
            let list = ms(5) { main.showScope(.all) }
            let folder = ms(5) { main.showScope(.folder(library.folders.first ?? "")) }
            done(["notes": library.notes.count, "searchMs": search, "allListMs": list, "folderListMs": folder])
        case "flush":
            SessionStore.shared.saveAll()
            delegate?.library?.flush()
            done(true)
        case "rescan":
            delegate?.library?.rescan { done(true) }
        case "windows":
            done(docs.map { d -> [String: Any] in
                let w = d.windowControllers.first?.window
                return ["path": d.fileURL?.path ?? "", "edited": d.isDocumentEdited,
                        "window": w?.windowNumber ?? 0, "title": w?.title ?? ""]
            })
        case "sidebar":
            guard let controller else { return done(nil) }
            done(["root": controller.sidebar.root?.path ?? "", "tab": "\(controller.sidebar.tab)",
                  "files": controller.sidebar.tree.map(\.name), "current": controller.sidebar.currentFile?.path ?? "",
                  "headings": controller.sidebar.headings.map(\.text), "currentHeading": controller.sidebar.currentHeading])
        case "js":
            guard let controller else { return done(nil) }
            controller.editor.evaluate(arg) { done($0) }
        case "action":
            // A menu action sent through the window's responder chain, like a menu click.
            let item = NSMenuItem()
            item.representedObject = command["represented"]
            let ok = window?.firstResponder?.tryToPerform(Selector(arg), with: item) ?? false
            done(ok)
        case "key":
            // A key press as the window would receive it (⌘-shortcuts go through key equivalents first).
            guard let window, let code = command["keyCode"] as? Int else { return done(false) }
            var flags: NSEvent.ModifierFlags = []
            for m in command["modifiers"] as? [String] ?? [] {
                switch m {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "option": flags.insert(.option)
                default: break
                }
            }
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: arg, charactersIgnoringModifiers: arg,
                isARepeat: false, keyCode: UInt16(code)) else { return done(false) }
            if flags.contains(.command) {
                if !window.performKeyEquivalent(with: event) { _ = NSApp.mainMenu?.performKeyEquivalent(with: event) }
            } else {
                window.makeFirstResponder(controller?.editor.webView)
                window.sendEvent(event)
            }
            done(true)
        case "save":
            guard let doc else { return done(nil) }
            doc.save(nil)
            waitUntil({ !doc.isDocumentEdited }) { done(!doc.isDocumentEdited) }
        case "exportHTML", "exportPDF":
            guard let controller else { return done(nil) }
            let url = URL(fileURLWithPath: arg)
            let finish: (Error?) -> Void = { error in done(error.map { "\($0)" } ?? "ok") }
            if command["action"] as? String == "exportPDF" {
                Exporter.writePDF(editor: controller.editor, to: url, done: finish)
            } else {
                Exporter.writeHTML(editor: controller.editor, to: url, done: finish)
            }
        case "setRoot":
            controller?.sidebar.setRoot(URL(fileURLWithPath: arg))
            done(true)
        case "tab":
            controller?.sidebar.tab = arg == "outline" ? .outline : .files
            done(true)
        case "openFromSidebar":
            controller?.openFromSidebar(URL(fileURLWithPath: arg))
            done(true)
        case "appearance":
            NSApp.appearance = arg == "dark" ? NSAppearance(named: .darkAqua) : arg == "light" ? NSAppearance(named: .aqua) : nil
            done(true)
        case "close":
            doc?.close()
            done(true)
        case "quit":
            done(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        default:
            done("unknown action")
        }
    }

    private static func waitUntil(_ condition: @escaping () -> Bool, tries: Int = 25, then: @escaping () -> Void) {
        if condition() || tries == 0 { return then() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitUntil(condition, tries: tries - 1, then: then) }
    }
}
#endif
