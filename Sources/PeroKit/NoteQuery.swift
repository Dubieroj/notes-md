import Foundation

/// What the notes list shows: a sidebar item.
public enum Scope: Hashable, Sendable {
    case all
    case quick
    case folder(String)
    case smart(String)
    case tags([String])
    case trash
}

public struct NoteGroup: Equatable {
    public var title: String
    public var notes: [NoteRecord]

    public init(title: String, notes: [NoteRecord]) {
        self.title = title
        self.notes = notes
    }
}

extension Library {
    /// Notes in a sidebar item, unsorted. For `.trash`, records of deleted notes.
    public func notes(in scope: Scope, now: Date = Date()) -> [NoteRecord] {
        switch scope {
        case .all: return Array(notes.values)
        case .quick: return notes.values.filter(\.isQuickNote)
        case .folder(let f): return notes.values.filter { $0.folder == f }
        case .smart(let id):
            guard let smart = state.smartFolders.first(where: { $0.id == id }) else { return [] }
            return notes(matching: smart, now: now)
        case .tags(let tags):
            // No tags chosen: «Все теги», every note that has one.
            if tags.isEmpty { return notes.values.filter { !$0.tags.isEmpty } }
            return notes.values.filter { r in tags.allSatisfy { r.hasTag($0) } }
        case .trash: return state.trash.compactMap { trashRecords[$0.id] }
        }
    }

    public func count(in scope: Scope) -> Int {
        switch scope {
        case .all: return notes.count
        case .trash: return state.trash.count
        default: return notes(in: scope).count
        }
    }

    public func notes(matching smart: SmartFolder, now: Date = Date()) -> [NoteRecord] {
        var queryHits: [String: Set<String>] = [:]
        for case .query(let q) in smart.filters { queryHits[q] = Set(search(q).map(\.path)) }
        return notes.values.filter { r in
            let results = smart.filters.map { matches(r, $0, now: now, queryHits: queryHits) }
            return smart.matchAll ? results.allSatisfy { $0 } : results.contains(true)
        }
    }

    private func matches(_ r: NoteRecord, _ filter: SmartFilter, now: Date, queryHits: [String: Set<String>]) -> Bool {
        switch filter {
        case .tags(let mode, let tags):
            switch mode {
            case .anySelected: return tags.contains { r.hasTag($0) }
            case .allSelected: return !tags.isEmpty && tags.allSatisfy { r.hasTag($0) }
            case .anyTag: return !r.tags.isEmpty
            case .noTags: return r.tags.isEmpty
            }
        case .created(let m, let a, let b): return Self.matches(r.created, m, a, b, now: now)
        case .edited(let m, let a, let b): return Self.matches(r.modified, m, a, b, now: now)
        case .checklists(let m):
            switch m {
            case .any: return r.tasksTotal > 0
            case .allChecked: return r.tasksTotal > 0 && r.tasksDone == r.tasksTotal
            case .someUnchecked: return r.tasksDone < r.tasksTotal
            case .none: return r.tasksTotal == 0
            }
        case .attachments(let m):
            switch m {
            case .any: return !r.flags.isDisjoint(with: .anyAttachment)
            case .images: return r.flags.contains(.images)
            case .scans: return r.flags.contains(.scans)
            case .pdfs: return r.flags.contains(.pdfs)
            case .documents: return r.flags.contains(.documents)
            case .sketches: return r.flags.contains(.sketches)
            case .audio: return r.flags.contains(.audio)
            case .none: return r.flags.isDisjoint(with: .anyAttachment)
            }
        case .folders(let include, let list):
            let inside = list.contains { r.folder == $0 || r.folder.hasPrefix($0 + "/") }
            return include == inside
        case .quickNotes(let yes): return r.isQuickNote == yes
        case .pinned(let yes): return isPinned(r.path) == yes
        case .locked(let yes): return r.isLocked == yes
        case .query(let q): return queryHits[q]?.contains(r.path) ?? false
        }
    }

    static func matches(_ date: Date, _ mode: DateMatch, _ a: Date?, _ b: Date?, now: Date) -> Bool {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: today)! }
        switch mode {
        case .today: return date >= today
        case .yesterday: return date >= daysAgo(1) && date < today
        case .last7Days: return date >= daysAgo(7)
        case .last30Days: return date >= daysAgo(30)
        case .last3Months: return date >= cal.date(byAdding: .month, value: -3, to: today)!
        case .last12Months: return date >= cal.date(byAdding: .month, value: -12, to: today)!
        case .before: return a.map { date < cal.startOfDay(for: $0) } ?? false
        case .after: return a.map { date >= cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: $0))! } ?? false
        case .between:
            guard let a, let b else { return false }
            return date >= cal.startOfDay(for: min(a, b)) && date < cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(a, b)))!
        }
    }
}

public enum NoteSorting {
    public static func sorted(_ notes: [NoteRecord], by key: SortKey, ascending: Bool) -> [NoteRecord] {
        notes.sorted { a, b in
            let result: ComparisonResult
            switch key {
            case .modified: result = a.modified == b.modified ? .orderedSame : (a.modified < b.modified ? .orderedAscending : .orderedDescending)
            case .created: result = a.created == b.created ? .orderedSame : (a.created < b.created ? .orderedAscending : .orderedDescending)
            case .title: result = a.displayTitle.localizedStandardCompare(b.displayTitle)
            }
            if result == .orderedSame { return a.path < b.path }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    /// Sections of the notes list, as in Notes: pinned first, then either one «Заметки»
    /// section or date groups (Сегодня, Вчера, Предыдущие 7 дней, Предыдущие 30 дней,
    /// months of this year, then years).
    public static func groups(_ notes: [NoteRecord], by key: SortKey, ascending: Bool, groupByDate: Bool,
                              isPinned: (String) -> Bool, now: Date = Date()) -> [NoteGroup] {
        let pinned = sorted(notes.filter { isPinned($0.path) }, by: key, ascending: ascending)
        let rest = sorted(notes.filter { !isPinned($0.path) }, by: key, ascending: ascending)
        var out: [NoteGroup] = []
        if !pinned.isEmpty { out.append(NoteGroup(title: PeroStrings.localize("Закреплённые"), notes: pinned)) }
        if groupByDate && key != .title {
            var order: [String] = []
            var buckets: [String: [NoteRecord]] = [:]
            for r in rest {
                let title = dateGroup(key == .created ? r.created : r.modified, now: now)
                if buckets[title] == nil { order.append(title) }
                buckets[title, default: []].append(r)
            }
            out += order.map { NoteGroup(title: $0, notes: buckets[$0]!) }
        } else if !rest.isEmpty {
            out.append(NoteGroup(title: pinned.isEmpty ? "" : PeroStrings.localize("Заметки"), notes: rest))
        }
        return out
    }

    public static func dateGroup(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let day = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return PeroStrings.localize("Сегодня") }
        if days == 1 { return PeroStrings.localize("Вчера") }
        if days <= 7 { return PeroStrings.localize("Предыдущие 7 дней") }
        if days <= 30 { return PeroStrings.localize("Предыдущие 30 дней") }
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            return monthFormatter.string(from: date).capitalized(with: monthFormatter.locale)
        }
        return String(cal.component(.year, from: date))
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = PeroStrings.locale
        f.dateFormat = "LLLL"
        return f
    }()
}
