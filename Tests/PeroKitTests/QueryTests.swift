import XCTest
@testable import PeroKit

final class QueryTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pero-q-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func record(_ path: String, modified: Date, title: String = "x") -> NoteRecord {
        NoteRecord(path: path, title: title, preview: "", created: modified, modified: modified, size: 0)
    }

    func testDateGroups() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!
        func ago(_ d: Int) -> Date { cal.date(byAdding: .day, value: -d, to: now)! }
        XCTAssertEqual(NoteSorting.dateGroup(now, now: now), "Сегодня")
        XCTAssertEqual(NoteSorting.dateGroup(ago(1), now: now), "Вчера")
        XCTAssertEqual(NoteSorting.dateGroup(ago(5), now: now), "Предыдущие 7 дней")
        XCTAssertEqual(NoteSorting.dateGroup(ago(20), now: now), "Предыдущие 30 дней")
        XCTAssertEqual(NoteSorting.dateGroup(ago(60), now: now), "Август")
        XCTAssertEqual(NoteSorting.dateGroup(ago(400), now: now), "2025")

        let notes = [record("a.md", modified: now), record("b.md", modified: ago(1)), record("c.md", modified: ago(3))]
        let groups = NoteSorting.groups(notes, by: .modified, ascending: false, groupByDate: true,
                                        isPinned: { $0 == "c.md" }, now: now)
        XCTAssertEqual(groups.map(\.title), ["Закреплённые", "Сегодня", "Вчера"])
        let flat = NoteSorting.groups(notes, by: .title, ascending: true, groupByDate: true, isPinned: { _ in false }, now: now)
        XCTAssertEqual(flat.map(\.title), [""])
    }

    func testSmartFolders() throws {
        let library = try Library(root: dir)
        let done = expectation(description: "scan")
        library.rescan { done.fulfill() }
        wait(for: [done], timeout: 5)
        let work = try library.createFolder(named: "Работа")
        let a = try library.createNote(in: work, text: "Задачи #срочно\n- [x] раз\n- [ ] два")
        let b = try library.createNote(in: "", text: "Готово\n- [x] всё")
        let c = try library.createNote(in: Library.quickFolder, text: "Быстрая")
        library.setPinned([b], true)

        func run(_ filters: [SmartFilter], all: Bool = true) -> Set<String> {
            Set(library.notes(matching: SmartFolder(name: "t", matchAll: all, filters: filters)).map(\.path))
        }
        XCTAssertEqual(run([.tags(.anySelected, ["СРОЧНО"])]), [a])
        XCTAssertEqual(run([.tags(.noTags, [])]), [b, c])
        XCTAssertEqual(run([.checklists(.allChecked)]), [b])
        XCTAssertEqual(run([.checklists(.someUnchecked)]), [a])
        XCTAssertEqual(run([.folders(include: true, [work])]), [a])
        XCTAssertEqual(run([.quickNotes(true)]), [c])
        XCTAssertEqual(run([.pinned(true)]), [b])
        XCTAssertEqual(run([.edited(.today, nil, nil)]), [a, b, c])
        XCTAssertEqual(run([.pinned(true), .quickNotes(true)], all: false), [b, c])
        XCTAssertEqual(run([.query("задачи")]), [a])

        XCTAssertEqual(Set(library.notes(in: .quick).map(\.path)), [c])
        XCTAssertEqual(Set(library.notes(in: .folder("")).map(\.path)), [b])
        XCTAssertEqual(Set(library.notes(in: .tags(["срочно"])).map(\.path)), [a])
        XCTAssertEqual(library.count(in: .all), 3)
    }
}

final class PathTests: XCTestCase {
    func testRelativeCopesWithDoubleSlashAndPrivate() {
        let root = URL(fileURLWithPath: "/var/folders/x/T//lib")
        XCTAssertEqual(Library.relative(URL(fileURLWithPath: "/private/var/folders/x/T/lib/Папка/Б.md"), to: root), "Папка/Б.md")
        XCTAssertEqual(Library.relative(URL(fileURLWithPath: "/var/folders/x/T//lib/А.md"), to: root), "А.md")
        XCTAssertNil(Library.relative(URL(fileURLWithPath: "/var/folders/x/T/other/А.md"), to: root))
    }
}
