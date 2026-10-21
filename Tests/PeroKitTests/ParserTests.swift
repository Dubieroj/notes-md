import XCTest
@testable import PeroKit

final class CodecTests: XCTestCase {
    func testRoundTripKeepsBytes() throws {
        let samples: [Data] = [
            Data("# Привет\n\nТекст\n".utf8),
            Data([0xEF, 0xBB, 0xBF] + Array("bom\n".utf8)),
            Data("a\r\nb\r\n".utf8),
            Data("mixed\r\nlines\n".utf8),
            "Кириллица 1251\n".data(using: .windowsCP1251)!,
        ]
        for data in samples {
            let buffer = try NoteBuffer(data: data)
            XCTAssertEqual(try buffer.data(), data)
        }
    }

    func testEditsApplyInUTF16() {
        let buffer = NoteBuffer(text: "ёж 🦔")
        XCTAssertTrue(buffer.applyEdits([[3, 2, "кот"]], expectedLength: 6))
        XCTAssertEqual(buffer.text, "ёж кот")
        XCTAssertFalse(buffer.applyEdits([[100, 1, ""]], expectedLength: nil))
    }
}

final class ParserTests: XCTestCase {
    func testTitleAndPreview() {
        let note = NoteParser.parse("# **Список** покупок\n\nМолоко и [хлеб](https://x.ru)\n- [ ] яйца\n")
        XCTAssertEqual(note.title, "Список покупок")
        XCTAssertEqual(note.preview, "Молоко и хлеб яйца")
        XCTAssertEqual(note.tasksTotal, 1)
        XCTAssertTrue(note.flags.contains(.checklists))
        XCTAssertTrue(note.flags.contains(.links))
    }

    func testPlainFirstLineIsTitle() {
        XCTAssertEqual(NoteParser.parse("\n\nПросто строка\nдальше").title, "Просто строка")
        XCTAssertEqual(NoteParser.parse("").title, "")
    }

    func testTags() {
        let note = NoteParser.parse("""
            # Заголовок
            Текст #работа и #Работа, #идея-1 но не#это, не `#код`, не https://a.ru/#якорь и не #2024
            [ссылка](https://x.ru/#frag) #проект_альфа
            """)
        XCTAssertEqual(note.tags, ["работа", "идея-1", "проект_альфа"])
    }

    func testTagsInsideCodeBlockIgnored() {
        let note = NoteParser.parse("Текст\n```\n#нетег\n```\n#тег")
        XCTAssertEqual(note.tags, ["тег"])
        XCTAssertTrue(note.flags.contains(.code))
    }

    func testFrontMatter() {
        let note = NoteParser.parse("---\ntags: [a, b]\n---\n# Настоящее название\n")
        XCTAssertEqual(note.title, "Настоящее название")
        XCTAssertEqual(note.tags, ["a", "b"])
    }

    func testWikiLinksAndAttachments() {
        let note = NoteParser.parse("""
            Заметка
            См. [[План запуска]] и [[Отчёт#Итоги|итоги]]
            ![фото](../Attachments/2026/10/abc-фото.jpg)
            [Договор](Attachments/x-договор.pdf)
            <img src="Attachments/y.png" width="300">
            """)
        XCTAssertEqual(note.wikiLinks, [WikiLink(target: "План запуска", section: nil), WikiLink(target: "Отчёт", section: "Итоги")])
        XCTAssertEqual(note.firstImage, "../Attachments/2026/10/abc-фото.jpg")
        XCTAssertTrue(note.flags.contains(.images))
        XCTAssertTrue(note.flags.contains(.pdfs))
        XCTAssertEqual(note.preview, "См. План запуска и итоги фото Договор")
    }

    func testTablesAndHeadings() {
        let note = NoteParser.parse("Название\n## Раздел\n| a | b |\n|---|:-:|\n| 1 | 2 |\n")
        XCTAssertTrue(note.flags.contains(.tables))
        XCTAssertEqual(note.headings, [Heading(level: 2, text: "Раздел", offset: 9)])
    }

    func testWords() {
        XCTAssertEqual(NoteParser.parse("Раз **два** три-четыре\n- [x] пять").words, 4)
    }
}

final class LinkRewriterTests: XCTestCase {
    func testResolveAndRelative() {
        XCTAssertEqual(LinkRewriter.resolve("../Attachments/a.png", from: "Работа"), "Attachments/a.png")
        XCTAssertNil(LinkRewriter.resolve("../../a.png", from: "Работа"))
        XCTAssertNil(LinkRewriter.resolve("https://x.ru/a.png", from: ""))
        XCTAssertEqual(LinkRewriter.relative(from: "Работа/Проект", to: "Attachments/a.png"), "../../Attachments/a.png")
        XCTAssertEqual(LinkRewriter.relative(from: "", to: "Attachments/a.png"), "Attachments/a.png")
        XCTAssertEqual(LinkRewriter.relative(from: "Работа", to: "Работа/Б.md"), "Б.md")
    }

    func testRebase() {
        let text = "![x](Attachments/a.png) [d](<Attachments/b c.pdf>) [w](https://x.ru) <img src=\"Attachments/i.png\">\n```\n![](Attachments/code.png)\n```"
        let out = LinkRewriter.rebase(text, from: "", to: "Работа")
        XCTAssertEqual(out, "![x](../Attachments/a.png) [d](<../Attachments/b c.pdf>) [w](https://x.ru) <img src=\"../Attachments/i.png\">\n```\n![](Attachments/code.png)\n```")
        XCTAssertNil(LinkRewriter.rebase("Без ссылок", from: "", to: "A"))
    }

    func testWikiRename() {
        let out = LinkRewriter.renameWikiLinks("[[План]] [[план|текст]] [[План#Раздел]] [[Планы]]", from: "План", to: "Новый план")
        XCTAssertEqual(out, "[[Новый план]] [[Новый план|текст]] [[Новый план#Раздел]] [[Планы]]")
    }

    func testFileNames() {
        XCTAssertEqual(FileNames.baseName(forTitle: "  Встреча 21/10: итоги "), "Встреча 21-10- итоги")
        XCTAssertEqual(FileNames.baseName(forTitle: ""), "Новая заметка")
        XCTAssertEqual(FileNames.baseName(forTitle: ".скрытая"), "скрытая")
        XCTAssertTrue(FileNames.matches("План 2", base: "План"))
        XCTAssertFalse(FileNames.matches("План Б", base: "План"))
        XCTAssertEqual(FileNames.attachmentName("Фото (1) со встречи.JPG"), "Фото-1-со-встречи.jpg")
    }
}

final class PlainTextTests: XCTestCase {
    func testPlainText() {
        let md = """
            # План
            Текст с **жирным** и [ссылкой](https://x.ru)
            - пункт
            + с тире
            1. первый
            - [ ] сделать
            - [x] готово
            > цитата
            | А | Б |
            |---|---|
            | 1 | 2 |
            ```
            код **как есть**
            ```
            ---
            """
        XCTAssertEqual(PlainText.from(md), """
            План
            Текст с жирным и ссылкой (https://x.ru)
            • пункт
            – с тире
            1. первый
            ☐ сделать
            ☑ готово
            цитата
            А\tБ
            1\t2
            код **как есть**
            ————————
            """)
    }

    func testEmptyNotes() {
        XCTAssertTrue(Library.isEmptyNote(""))
        XCTAssertTrue(Library.isEmptyNote("# "))
        XCTAssertTrue(Library.isEmptyNote("\n\n## \n"))
        XCTAssertFalse(Library.isEmptyNote("# Привет"))
        XCTAssertFalse(Library.isEmptyNote("![](Attachments/x.png)"))
        XCTAssertFalse(Library.isEmptyNote("- [ ] "))
    }
}
