import CryptoKit
import XCTest
@testable import PeroKit

final class LibraryTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pero-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func open() throws -> Library {
        let library = try Library(root: dir)
        wait(library)
        return library
    }

    func wait(_ library: Library) {
        let done = expectation(description: "scan")
        library.rescan { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    func text(_ library: Library, _ path: String) throws -> String {
        try String(contentsOf: library.url(path), encoding: .utf8)
    }

    func testScanFindsNotesAndFolders() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Работа/Проект"), withIntermediateDirectories: true)
        try "# План\nТекст #работа".write(to: dir.appendingPathComponent("Работа/План.md"), atomically: true, encoding: .utf8)
        try "Корень".write(to: dir.appendingPathComponent("Корень.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Attachments/2026"), withIntermediateDirectories: true)
        try "не заметка".write(to: dir.appendingPathComponent("Attachments/2026/x.md"), atomically: true, encoding: .utf8)
        let library = try open()
        XCTAssertEqual(Set(library.notes.keys), ["Работа/План.md", "Корень.md"])
        XCTAssertEqual(library.folders, ["Работа", "Работа/Проект"])
        XCTAssertEqual(library.notes["Работа/План.md"]?.tags, ["работа"])
        XCTAssertEqual(library.tagCounts().map(\.tag), ["работа"])
    }

    func testCreateSaveRename() throws {
        let library = try open()
        let path = try library.createNote(in: "")
        XCTAssertEqual(path, "Новая заметка.md")
        let buffer = try library.loadBuffer(path)
        buffer.setText("# Встреча с Олей\nОбсудили план")
        try library.save(path, buffer: buffer)
        XCTAssertEqual(library.record(path)?.title, "Встреча с Олей")
        let created = try FileManager.default.attributesOfItem(atPath: library.url(path).path)[.creationDate] as? Date
        let renamed = try library.renameToMatchTitle(path)
        XCTAssertEqual(renamed, "Встреча с Олей.md")
        XCTAssertNil(library.record(path))
        XCTAssertEqual(try text(library, renamed), "# Встреча с Олей\nОбсудили план")
        // Saving again keeps the creation date of the file.
        Thread.sleep(forTimeInterval: 1.1)
        try library.save(renamed, buffer: buffer)
        let after = try FileManager.default.attributesOfItem(atPath: library.url(renamed).path)[.creationDate] as? Date
        XCTAssertEqual(created, after)
    }

    func testMoveRewritesAttachmentLinks() throws {
        let library = try open()
        let image = try library.addAttachment(data: Data([1, 2, 3]), name: "фото.png")
        XCTAssertTrue(image.hasPrefix("Attachments/"))
        let target = library.linkTarget(to: image, fromFolder: "")
        let path = try library.createNote(in: "", text: "Фото\n![](\(target))")
        let again = try library.addAttachment(data: Data([1, 2, 3]), name: "другое.png")
        XCTAssertEqual(again, image, "the same file is not copied twice")
        let folder = try library.createFolder(named: "Работа")
        let moves = try library.move([path], to: folder)
        let newPath = try XCTUnwrap(moves[path])
        XCTAssertEqual(newPath, "Работа/Фото.md")
        XCTAssertEqual(try text(library, newPath), "Фото\n![](../\(image))")
        XCTAssertEqual(library.record(newPath)?.firstImage, image)
    }

    func testMovingAFolderKeepsLinksInsideIt() throws {
        let library = try open()
        let a = try library.createFolder(named: "A")
        let b = try library.createFolder(named: "B")
        try FileManager.default.createDirectory(at: library.url("A/img"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: library.url("A/img/p.png"))
        _ = try library.createNote(in: a, text: "Игрек")
        let x = try library.createNote(in: a, text: "Икс\n[y](Игрек.md) ![](img/p.png) [out](../Снаружи.md)")
        _ = try library.createNote(in: "", text: "Снаружи")
        let moved = try library.moveFolder(a, into: b)
        XCTAssertEqual(moved, "B/A")
        XCTAssertEqual(try text(library, "B/A/" + (x as NSString).lastPathComponent),
                       "Икс\n[y](Игрек.md) ![](img/p.png) [out](../../Снаружи.md)")
    }

    func testMovingNotesTogetherKeepsLinksBetweenThem() throws {
        let library = try open()
        let one = try library.createNote(in: "", text: "Один\n[два](Два.md)")
        let two = try library.createNote(in: "", text: "Два\n[один](Один.md)")
        let folder = try library.createFolder(named: "Вместе")
        let moves = try library.move([one, two], to: folder)
        XCTAssertEqual(try text(library, try XCTUnwrap(moves[one])), "Один\n[два](Два.md)")
        XCTAssertEqual(try text(library, try XCTUnwrap(moves[two])), "Два\n[один](Один.md)")
    }

    func testUnsafeTrashEntriesAreIgnored() throws {
        let item = { (id: String, file: String, original: String) in
            TrashItem(id: id, originalPath: original, deletedAt: Date(), file: file)
        }
        let id = UUID().uuidString
        XCTAssertTrue(item(id, id + "/Заметка.md", "Папка/Заметка.md").isWellFormed)
        XCTAssertFalse(item("../..", "../../x.md", "x.md").isWellFormed)
        XCTAssertFalse(item(id, id + "/..", "x.md").isWellFormed)
        XCTAssertFalse(item(id, id + "/a/b.md", "x.md").isWellFormed)
        XCTAssertFalse(item(id, id + "/x.md", "../../x.md").isWellFormed)
        XCTAssertFalse(Library.isInsideFolder("../Desktop"))
        XCTAssertFalse(Library.isInsideFolder("/etc"))
        XCTAssertTrue(Library.isInsideFolder("Работа/Март"))
    }

    func testTextOutsideTheEncodingSwitchesToUTF8() throws {
        let buffer = try NoteBuffer(data: Data([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2]))  // «Привет» in Windows-1251
        XCTAssertEqual(buffer.text, "Привет")
        buffer.setText("Привет 🙂")
        XCTAssertEqual(String(data: try buffer.data(), encoding: .utf8), "Привет 🙂")
    }

    func testChangingOnlyTheCaseRenamesInPlace() throws {
        let library = try open()
        let path = try library.createNote(in: "", text: "привет")
        let buffer = try library.loadBuffer(path)
        buffer.setText("Привет")
        try library.save(path, buffer: buffer)
        XCTAssertEqual(try library.renameToMatchTitle(path), "Привет.md")
        let folder = try library.createFolder(named: "работа")
        XCTAssertEqual(try library.renameFolder(folder, to: "Работа"), "Работа")
        let names = try FileManager.default.contentsOfDirectory(atPath: library.root.path).map { $0.precomposedStringWithCanonicalMapping }
        XCTAssertTrue(names.contains("Привет.md") && names.contains("Работа"), "\(names)")
    }

    func testTrashRestoreAndPurge() throws {
        let library = try open()
        let path = try library.createNote(in: "", text: "Удалить меня")
        library.setPinned([path], true)
        let original = try Data(contentsOf: library.url(path))
        let ids = try library.trash([path], now: Date(timeIntervalSinceNow: -10 * 86400))
        XCTAssertNil(library.record(path))
        XCTAssertFalse(library.isPinned(path))
        XCTAssertEqual(library.trash.first?.daysLeft(), 20)
        XCTAssertEqual(library.trashRecords[ids[0]]?.title, "Удалить меня")
        let restored = try library.restore(ids)
        XCTAssertEqual(restored, [path])
        XCTAssertEqual(try Data(contentsOf: library.url(path)), original)

        let old = try library.trash([path], now: Date(timeIntervalSinceNow: -31 * 86400))
        library.purgeExpiredTrash()
        XCTAssertTrue(library.trash.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.trashURL(TrashItem(id: old[0], originalPath: path, deletedAt: Date(), file: old[0])).path))
    }

    func testFoldersRenameMoveDelete() throws {
        let library = try open()
        let a = try library.createFolder(named: "А")
        let note = try library.createNote(in: a, text: "Внутри")
        library.setPinned([note], true)
        let b = try library.renameFolder(a, to: "Б")
        XCTAssertEqual(b, "Б")
        XCTAssertTrue(library.isPinned("Б/Внутри.md"))
        let parent = try library.createFolder(named: "Родитель")
        let moved = try library.moveFolder(b, into: parent)
        XCTAssertEqual(moved, "Родитель/Б")
        XCTAssertNotNil(library.record("Родитель/Б/Внутри.md"))
        try library.deleteFolder(parent)
        XCTAssertNil(library.record("Родитель/Б/Внутри.md"))
        XCTAssertEqual(library.trash.count, 1)
        XCTAssertFalse(library.folders.contains(parent))
    }

    func testTagRenameAndSearch() throws {
        let library = try open()
        let one = try library.createNote(in: "", text: "Ёлка #дом\nзелёная")
        _ = try library.createNote(in: "", text: "Другая #Дом #работа")
        XCTAssertEqual(library.search("елк").map(\.path), [one])
        XCTAssertEqual(library.search("зелен ёлка").map(\.path), [one])
        XCTAssertEqual(try library.replaceTag("дом", with: "квартира"), 2)
        XCTAssertEqual(try text(library, one), "Ёлка #квартира\nзелёная")
        XCTAssertEqual(Set(library.tagCounts().map(\.tag)), ["квартира", "работа"])
        try library.replaceTag("работа", with: nil)
        XCTAssertFalse(library.tagCounts().contains { $0.tag == "работа" })
    }

    func testWikiLinksFollowRename() throws {
        let library = try open()
        let target = try library.createNote(in: "", text: "План")
        let source = try library.createNote(in: "", text: "Ссылки\n[[План]] и [[План#Итоги]]")
        XCTAssertEqual(library.resolveWikiLink("план")?.path, target)
        XCTAssertEqual(library.backlinks(to: try XCTUnwrap(library.record(target))).map(\.path), [source])
        XCTAssertEqual(library.renameWikiLinks(from: "План", to: "Новый план", except: target), 1)
        XCTAssertEqual(try text(library, source), "Ссылки\n[[Новый план]] и [[Новый план#Итоги]]")
    }

    func testExternalChangesAreSeen() throws {
        let library = try open()
        try "Снаружи".write(to: dir.appendingPathComponent("Снаружи.md"), atomically: true, encoding: .utf8)
        wait(library)
        XCTAssertEqual(library.record("Снаружи.md")?.title, "Снаружи")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Снаружи.md"))
        wait(library)
        XCTAssertNil(library.record("Снаружи.md"))
    }

    func testIndexSurvivesReopen() throws {
        var library: Library? = try open()
        _ = try library!.createNote(in: "", text: "Сохранится")
        library!.flush()
        library = nil
        let reopened = try Library(root: dir)
        XCTAssertNotNil(reopened.record("Сохранится.md"), "records come from the index before the scan")
        XCTAssertEqual(reopened.search("сохран").count, 1)
    }

    func testLocking() throws {
        let library = try open()
        let path = try library.createNote(in: "", text: "Секрет\nпароль от сейфа")
        let locker = NoteLocker(library: library)
        let master = try locker.setPassword("1234", hint: "цифры")
        let locked = try library.lock(path, master: master)
        XCTAssertEqual(locked, "Секрет.pero-locked")
        let raw = try String(contentsOf: library.url(locked), encoding: .utf8)
        XCTAssertFalse(raw.contains("сейфа"))
        XCTAssertTrue(library.record(locked)?.isLocked ?? false)
        XCTAssertEqual(library.record(locked)?.title, "Секрет")
        XCTAssertTrue(library.search("сейф").isEmpty)
        XCTAssertThrowsError(try locker.unlock(password: "0000"))
        let again = try NoteLocker(library: library).unlock(password: "1234")
        XCTAssertEqual(try library.readLocked(locked, master: again), "Секрет\nпароль от сейфа")
        try locker.changePassword(from: "1234", to: "5678", hint: nil)
        let changed = try locker.unlock(password: "5678")
        let plain = try library.removeLock(locked, master: changed)
        XCTAssertEqual(try text(library, plain), "Секрет\nпароль от сейфа")
    }

    func testConvertToSmartFolder() throws {
        let library = try open()
        let folder = try library.createFolder(named: "Рецепты")
        _ = try library.createNote(in: folder, text: "Борщ")
        let smart = try library.convertToSmartFolder(folder)
        XCTAssertEqual(smart.filters, [.tags(.anySelected, ["Рецепты"])])
        XCTAssertEqual(try text(library, "Борщ.md"), "Борщ\n\n#Рецепты\n")
        XCTAssertFalse(library.folders.contains(folder))
    }
}

final class ReopenTests: XCTestCase {
    func testReopenDoesNotReparseUnchangedNotes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pero-reopen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<20 { try "Заметка \(i)".write(to: dir.appendingPathComponent("\(i).md"), atomically: true, encoding: .utf8) }
        var library: Library? = try Library(root: dir)
        let first = expectation(description: "scan")
        library!.rescan { first.fulfill() }
        wait(for: [first], timeout: 10)
        library!.flush()
        library = nil
        let reopened = try Library(root: dir)
        var changed: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: Library.didChange, object: reopened, queue: nil) { note in
            changed += note.userInfo?["changed"] as? [String] ?? []
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let second = expectation(description: "rescan")
        reopened.rescan { second.fulfill() }
        wait(for: [second], timeout: 10)
        XCTAssertEqual(changed, [], "unchanged files must not be read again on launch")
        XCTAssertEqual(reopened.notes.count, 20)
    }
}

final class LinkedFolderTests: XCTestCase {
    func testDataLivesOutsideTheLinkedFolder() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("pero-linked-" + UUID().uuidString)
        let folder = base.appendingPathComponent("Расшифровки")
        let meta = base.appendingPathComponent("meta")
        try fm.createDirectory(at: folder.appendingPathComponent("Март"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try "# Встреча\nТекст #созвон".write(to: folder.appendingPathComponent("Март/Встреча.md"), atomically: true, encoding: .utf8)
        let picture = base.appendingPathComponent("pic.png")
        try Data([1, 2, 3]).write(to: picture)
        try "Картинка снаружи\n![](\(picture.path))".write(to: folder.appendingPathComponent("Снаружи.md"), atomically: true, encoding: .utf8)

        let library = try Library(root: folder, meta: meta)
        let done = expectation(description: "scan")
        library.rescan { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(Set(library.notes.keys), ["Март/Встреча.md", "Снаружи.md"])
        XCTAssertEqual(library.tagCounts().map(\.tag), ["созвон"])
        XCTAssertTrue(library.record("Снаружи.md")?.firstImage?.hasSuffix("/pic.png") ?? false)
        XCTAssertEqual(library.fileURL(for: picture.path).path, picture.path)
        // Nothing of Перо's own goes into the user's folder.
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent(".pero").path))
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent(".gitignore").path))
        XCTAssertTrue(fm.fileExists(atPath: meta.appendingPathComponent("cache/index.sqlite").path))
        // Edits and the trash work in place.
        let buffer = try library.loadBuffer("Март/Встреча.md")
        buffer.setText("# Встреча\nПравка на месте")
        try library.save("Март/Встреча.md", buffer: buffer)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Март/Встреча.md"), encoding: .utf8), "# Встреча\nПравка на месте")
        try library.trash(["Снаружи.md"])
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent("Снаружи.md").path))
        XCTAssertEqual(library.trash.count, 1)
        XCTAssertThrowsError(try Library(root: base.appendingPathComponent("нет такой папки"), meta: meta))
    }
}

final class RenamePolicyTests: XCTestCase {
    func testLinkedFoldersKeepFileNames() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("pero-names-" + UUID().uuidString)
        try fm.createDirectory(at: base.appendingPathComponent("notes"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try "# Совсем другое название".write(to: base.appendingPathComponent("notes/2026-10-21 расшифровка.md"), atomically: true, encoding: .utf8)
        let library = try Library(root: base.appendingPathComponent("notes"), meta: base.appendingPathComponent("meta"))
        library.renamesFilesAfterTitle = false
        let done = expectation(description: "scan")
        library.rescan { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertNil(library.pathMatchingTitle("2026-10-21 расшифровка.md"))
        XCTAssertEqual(try library.renameToMatchTitle("2026-10-21 расшифровка.md"), "2026-10-21 расшифровка.md")
    }
}
