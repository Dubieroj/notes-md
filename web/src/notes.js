// Notes formatting commands that write Markdown: paragraph styles, lists, checklists,
// tables, dividers, indentation. Each command is one undo step.
import {EditorSelection} from "@codemirror/state"
import {moveLineUp, moveLineDown, insertNewlineAndIndent} from "@codemirror/commands"
import {syntaxTree} from "@codemirror/language"
import {ctx} from "./ctx.js"
import {toggleWrap} from "./format.js"

// indent, quote prefix, then a heading or a list marker with an optional task box.
const prefixRe = /^([ \t]*)((?:>[ \t]?)*)(?:(#{1,6})(?:[ \t]+|$)|([-*+]|\d+[.)])(?:[ \t]+|$)(?:\[([ xX])\](?:[ \t]+|$))?)?/

export function lineInfo(text) {
  const m = prefixRe.exec(text)
  const marker = m[4] || null
  const markerWidth = marker ? /^([-*+]|\d+[.)])[ \t]*/.exec(text.slice(m[1].length + m[2].length))[0].length : 0
  return {
    markerWidth,
    indent: m[1],
    quote: m[2],
    heading: m[3] ? m[3].length : 0,
    marker,
    list: marker ? (/\d/.test(marker) ? "number" : marker === "+" ? "dash" : "bullet") : null,
    task: m[5] === undefined ? null : m[5] !== " ",
    prefixLength: m[0].length,
    content: text.slice(m[0].length),
  }
}

function selectedLines(state) {
  const numbers = new Set()
  for (const r of state.selection.ranges) {
    const first = state.doc.lineAt(r.from).number
    let last = state.doc.lineAt(r.to).number
    // A selection ending at the start of a line does not include that line.
    if (last > first && r.to === state.doc.line(last).from) last--
    for (let n = first; n <= last; n++) numbers.add(n)
  }
  const lines = [...numbers].sort((a, b) => a - b).map((n) => state.doc.line(n))
  // Blank lines inside a multi-line selection keep their style (none).
  return lines.length > 1 ? lines.filter((l) => l.text.trim() !== "") : lines
}

// The fenced or indented code block a line is part of, if any.
function codeBlockAt(state, line) {
  let found = null
  syntaxTree(state).iterate({from: line.from, to: line.to, enter: (n) => {
    if (found) return false
    if (n.name === "FencedCode" || n.name === "CodeBlock") { found = n.node; return false }
  }})
  return found
}

// Last line of YAML front matter, or 0.
function frontMatterEnd(doc) {
  if (doc.line(1).text !== "---") return 0
  for (let i = 2; i <= Math.min(doc.lines, 200); i++) if (/^(---|\.\.\.)$/.test(doc.line(i).text)) return i
  return 0
}

function dispatchChanges(view, changes, extra = {}) {
  if (!changes.length) return true
  view.dispatch(view.state.update({changes, scrollIntoView: true, userEvent: "input.format", ...extra}))
  return true
}

// ---------- paragraph styles (Title, Heading, Subheading, Body, lists, quote) ----------

function prefixFor(style, info, number) {
  switch (style) {
    case "body": return ""
    case "h1": case "h2": case "h3": case "h4": case "h5": case "h6":
      return "#".repeat(Number(style[1])) + " "
    case "bullet": return info.indent + "- "
    case "dash": return info.indent + "+ "
    case "number": return info.indent + number + ". "
    case "checklist": return info.indent + (info.list === "number" ? info.marker : info.list === "dash" ? "+" : "-") + " [ ] "
  }
  return ""
}

function isStyle(info, style) {
  if (/^h\d$/.test(style)) return info.heading === Number(style[1])
  if (style === "checklist") return info.task !== null
  if (style === "body") return false
  return info.list === style && info.task === null
}

export function setStyle(style) {
  return (view) => {
    const {state} = view
    // Code and front matter are not paragraphs: their lines keep their text.
    const meta = frontMatterEnd(state.doc)
    const lines = selectedLines(state).filter((l) => l.number > meta && !codeBlockAt(state, l))
    if (!lines.length) return false
    const infos = lines.map((l) => lineInfo(l.text))
    // Applying the style every line already has turns it back into body text.
    const off = style !== "body" && infos.every((i) => isStyle(i, style))
    let number = 1
    if (style === "number" && !off) {
      // Continue the numbering of a list right above.
      const above = lines[0].number > 1 ? lineInfo(state.doc.line(lines[0].number - 1).text) : null
      if (above && above.list === "number" && above.indent === infos[0].indent) number = parseInt(above.marker, 10) + 1
    }
    const changes = []
    lines.forEach((line, i) => {
      const info = infos[i]
      const target = off ? "body" : style
      // Headings and body text leave lists and quotes behind; lists keep the quote.
      const keepQuote = target !== "body" && !/^h\d$/.test(target)
      const prefix = (keepQuote ? info.quote : "") + prefixFor(target, info, number++)
      changes.push({from: line.from, to: line.from + info.prefixLength, insert: prefix})
    })
    return dispatchChanges(view, changes)
  }
}

export function toggleQuote(view) {
  const lines = selectedLines(view.state)
  const all = lines.every((l) => /^[ \t]*>/.test(l.text))
  const changes = lines.map((l) => {
    if (all) {
      const m = /^([ \t]*)>[ \t]?/.exec(l.text)
      return {from: l.from + m[1].length, to: l.from + m[0].length, insert: ""}
    }
    return {from: l.from, insert: "> "}
  })
  return dispatchChanges(view, changes)
}

// Monostyled: a code block for whole lines, inline code inside a line.
export function toggleMono(view) {
  const {state} = view
  const r = state.selection.main
  const line = state.doc.lineAt(r.from)
  if (!r.empty && r.to <= line.to && !(r.from === line.from && r.to === line.to)) return toggleWrap("`")(view)
  const first = state.doc.lineAt(r.from), last = state.doc.lineAt(r.to)
  const code = codeBlockAt(state, first)
  if (code?.name === "FencedCode") {
    // Inside a code block: drop its fence lines.
    const marks = code.getChildren("CodeMark")
    const open = state.doc.lineAt(code.from)
    const changes = [{from: open.from, to: Math.min(open.to + 1, state.doc.length)}]
    if (marks.length > 1) {
      const close = state.doc.lineAt(marks[marks.length - 1].from)
      changes.push({from: close.from - 1, to: close.to})
    }
    return dispatchChanges(view, changes)
  }
  return dispatchChanges(view, [{from: first.from, insert: "```\n"}, {from: last.to, insert: "\n```"}])
}

export function toggleWrapPair(open, close) {
  return (view) => {
    const {state} = view
    const tr = state.changeByRange((range) => {
      const before = state.sliceDoc(range.from - open.length, range.from)
      const after = state.sliceDoc(range.to, range.to + close.length)
      if (before === open && after === close) {
        return {
          changes: [{from: range.from - open.length, to: range.from}, {from: range.to, to: range.to + close.length}],
          range: EditorSelection.range(range.from - open.length, range.to - open.length),
        }
      }
      return {
        changes: [{from: range.from, insert: open}, {from: range.to, insert: close}],
        range: EditorSelection.range(range.from + open.length, range.to + open.length),
      }
    })
    view.dispatch(state.update(tr, {scrollIntoView: true, userEvent: "input.format"}))
    return true
  }
}

// ---------- checklists ----------

// The contiguous run of task lines at the indent of `lineNumber`, with the lines nested under them.
function checklistBlock(state, lineNumber) {
  const isTask = (n) => n >= 1 && n <= state.doc.lines && lineInfo(state.doc.line(n).text).task !== null
  if (!isTask(lineNumber)) return null
  const indent = lineInfo(state.doc.line(lineNumber).text).indent.length
  let first = lineNumber, last = lineNumber
  const inBlock = (n) => {
    if (n < 1 || n > state.doc.lines) return false
    const text = state.doc.line(n).text
    const depth = lineInfo(text).indent.length
    return text.trim() !== "" && (depth > indent || (depth === indent && isTask(n)))
  }
  while (inBlock(first - 1)) first--
  while (inBlock(last + 1)) last++
  return {first, last, indent}
}

// Items of a checklist at its indent, each with its nested lines.
function checklistItems(state, block) {
  const top = block.indent
  const items = []
  for (let n = block.first; n <= block.last; n++) {
    const text = state.doc.line(n).text
    const info = lineInfo(text)
    if (info.task !== null && info.indent.length <= top) items.push({checked: info.task, lines: [text]})
    else if (items.length) items[items.length - 1].lines.push(text)
    else items.push({checked: false, lines: [text]})
  }
  return items
}

function rewriteBlock(view, block, items, extra) {
  const {state} = view
  const from = state.doc.line(block.first).from, to = state.doc.line(block.last).to
  const insert = items.flatMap((i) => i.lines).join("\n")
  if (insert === state.sliceDoc(from, to)) return false
  view.dispatch({changes: {from, to, insert}, userEvent: "input.format", ...extra})
  return true
}

// Notes's «Automatically sort checked items»: unchecked first, checked last.
export function sortChecklistAt(view, pos) {
  const block = checklistBlock(view.state, view.state.doc.lineAt(pos).number)
  if (!block) return false
  const items = checklistItems(view.state, block)
  const sorted = [...items.filter((i) => !i.checked), ...items.filter((i) => i.checked)]
  return rewriteBlock(view, block, sorted)
}

function setTaskAt(view, lineNumber, checked) {
  const line = view.state.doc.line(lineNumber)
  const m = /\[([ xX])\]/.exec(line.text.slice(lineInfo(line.text).indent.length))
  if (!m) return null
  const at = line.from + lineInfo(line.text).indent.length + m.index + 1
  return {from: at, to: at + 1, insert: checked ? "x" : " "}
}

export function toggleCheck(view) {
  const lines = selectedLines(view.state).filter((l) => lineInfo(l.text).task !== null)
  if (!lines.length) return false
  const changes = lines.map((l) => setTaskAt(view, l.number, !lineInfo(l.text).task)).filter(Boolean)
  dispatchChanges(view, changes)
  if (ctx.autoSortChecked) sortChecklistAt(view, view.state.selection.main.head)
  return true
}

function eachTaskInBlock(view, fn) {
  const block = checklistBlock(view.state, view.state.doc.lineAt(view.state.selection.main.head).number)
  if (!block) return false
  const changes = []
  for (let n = block.first; n <= block.last; n++) {
    const info = lineInfo(view.state.doc.line(n).text)
    if (info.task !== null) { const c = fn(n, info); if (c) changes.push(c) }
  }
  return dispatchChanges(view, changes)
}

export const checkAll = (view) => eachTaskInBlock(view, (n, i) => (i.task ? null : setTaskAt(view, n, true)))
export const uncheckAll = (view) => eachTaskInBlock(view, (n, i) => (i.task ? setTaskAt(view, n, false) : null))

export function moveCheckedDown(view) {
  return sortChecklistAt(view, view.state.selection.main.head)
}

export function deleteChecked(view) {
  const block = checklistBlock(view.state, view.state.doc.lineAt(view.state.selection.main.head).number)
  if (!block) return false
  const items = checklistItems(view.state, block).filter((i) => !i.checked)
  if (!items.length) items.push({checked: false, lines: [lineInfo(view.state.doc.line(block.first).text).indent + "- [ ] "]})
  return rewriteBlock(view, block, items)
}

// ---------- indentation ----------

function itemEnd(state, lineNumber) {
  // A list item with the lines nested under it.
  const indent = lineInfo(state.doc.line(lineNumber).text).indent.length
  let last = lineNumber
  for (let n = lineNumber + 1; n <= state.doc.lines; n++) {
    const text = state.doc.line(n).text
    if (text.trim() === "") break
    if (lineInfo(text).indent.length <= indent) break
    last = n
  }
  return last
}

export function indentItem(view) {
  const {state} = view
  const lines = selectedLines(state).filter((l) => lineInfo(l.text).list)
  if (!lines.length) return false
  const changes = []
  const done = new Set()
  for (const line of lines) {
    if (done.has(line.number)) continue
    const info = lineInfo(line.text)
    // Nest under the previous item: indent to where its text starts.
    let target = null
    for (let n = line.number - 1; n >= 1; n--) {
      const t = state.doc.line(n).text
      if (t.trim() === "") break
      const p = lineInfo(t)
      if (p.list && p.indent.length <= info.indent.length) { target = p.indent.length + p.markerWidth; break }
    }
    if (target == null || target <= info.indent.length) continue
    const add = " ".repeat(target - info.indent.length)
    for (let n = line.number; n <= itemEnd(state, line.number); n++) {
      done.add(n)
      changes.push({from: state.doc.line(n).from, insert: add})
    }
  }
  return dispatchChanges(view, changes) && changes.length > 0
}

export function outdentItem(view) {
  const {state} = view
  const lines = selectedLines(state).filter((l) => lineInfo(l.text).list && lineInfo(l.text).indent.length > 0)
  if (!lines.length) return false
  const changes = []
  const done = new Set()
  for (const line of lines) {
    if (done.has(line.number)) continue
    const info = lineInfo(line.text)
    let target = 0
    for (let n = line.number - 1; n >= 1; n--) {
      const t = state.doc.line(n).text
      if (t.trim() === "") break
      const p = lineInfo(t)
      if (p.list && p.indent.length < info.indent.length) { target = p.indent.length; break }
    }
    const remove = info.indent.length - target
    for (let n = line.number; n <= itemEnd(state, line.number); n++) {
      done.add(n)
      const l = state.doc.line(n)
      const lead = /^[ \t]*/.exec(l.text)[0].length
      changes.push({from: l.from, to: l.from + Math.min(remove, lead)})
    }
  }
  return dispatchChanges(view, changes)
}

// Tab: nest a list item, move between table cells, otherwise a tab character.
function tab(view) {
  if (tableTab(view, 1)) return true
  if (indentItem(view)) return true
  if (lineInfo(view.state.doc.lineAt(view.state.selection.main.head).text).list) return true
  view.dispatch(view.state.replaceSelection("\t"))
  return true
}

function shiftTab(view) {
  if (tableTab(view, -1)) return true
  outdentItem(view)
  return true
}

// Shift-Return inside a list item: a line break in the same item.
function softBreak(view) {
  const {state} = view
  const line = state.doc.lineAt(state.selection.main.head)
  const info = lineInfo(line.text)
  if (!info.list) return false
  const pad = " ".repeat(info.prefixLength - info.quote.length)
  view.dispatch(state.replaceSelection("\\\n" + info.quote + pad), {scrollIntoView: true, userEvent: "input"})
  return true
}

// ---------- tables ----------

function splitCells(text) {
  // Cell boundaries: unescaped pipes.
  const pipes = []
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "\\") { i++; continue }
    if (text[i] === "|") pipes.push(i)
  }
  return pipes
}

const separatorRe = /^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/

function tableAt(state, pos) {
  const lineNo = state.doc.lineAt(pos).number
  const isRow = (n) => n >= 1 && n <= state.doc.lines && state.doc.line(n).text.includes("|") && state.doc.line(n).text.trim() !== ""
  if (!isRow(lineNo)) return null
  let first = lineNo, last = lineNo
  while (isRow(first - 1)) first--
  while (isRow(last + 1)) last++
  if (last - first < 1 || !separatorRe.test(state.doc.line(first + 1).text)) return null
  const rows = []
  for (let n = first; n <= last; n++) {
    const line = state.doc.line(n)
    rows.push({line, pipes: splitCells(line.text)})
  }
  return {first, last, rows}
}

function cellRanges(row) {
  // [from, to] of each cell's text, trimmed of the spaces around it.
  const text = row.line.text
  const bounds = [...row.pipes]
  const lead = text.trimStart().startsWith("|")
  const trail = text.trimEnd().endsWith("|")
  const edges = lead ? bounds : [-1, ...bounds]
  if (!trail) edges.push(text.length)
  const cells = []
  for (let i = 0; i < edges.length - 1; i++) {
    let a = edges[i] + 1, b = edges[i + 1]
    while (a < b && text[a] === " ") a++
    while (b > a && text[b - 1] === " ") b--
    cells.push({from: row.line.from + a, to: row.line.from + b})
  }
  return cells
}

function tableTab(view, dir) {
  const {state} = view
  const pos = state.selection.main.head
  const table = tableAt(state, pos)
  if (!table) return false
  const flat = []
  table.rows.forEach((row, i) => { if (i !== 1) cellRanges(row).forEach((c) => flat.push(c)) })
  let index = flat.findIndex((c) => pos <= c.to + 1 && pos >= c.from - 1)
  if (index < 0) index = 0
  const next = index + dir
  if (next >= flat.length) return addRow(view, 1) // the cursor lands in its first cell
  if (next < 0) return true
  view.dispatch({selection: EditorSelection.range(flat[next].from, flat[next].to), scrollIntoView: true})
  return true
}

function emptyRow(columns) {
  return "|" + "  |".repeat(columns)
}

function currentColumn(table, pos) {
  for (const row of table.rows) {
    if (pos < row.line.from || pos > row.line.to) continue
    const cells = cellRanges(row)
    const i = cells.findIndex((c) => pos <= c.to + 1)
    return i < 0 ? cells.length - 1 : i
  }
  return 0
}

export function addRow(view, dir = 1) {
  const {state} = view
  const pos = state.selection.main.head
  const table = tableAt(state, pos)
  if (!table) return false
  const lineNo = state.doc.lineAt(pos).number
  const columns = cellRanges(table.rows[0]).length
  const row = emptyRow(columns)
  let at, cursor
  if (dir > 0 || lineNo <= table.first + 1) {
    const base = state.doc.line(Math.max(lineNo, table.first + 1))
    at = base.to
    view.dispatch({changes: {from: at, insert: "\n" + row}, selection: {anchor: at + 3}, userEvent: "input.table"})
  } else {
    const base = state.doc.line(lineNo)
    at = base.from
    view.dispatch({changes: {from: at, insert: row + "\n"}, selection: {anchor: at + 2}, userEvent: "input.table"})
  }
  return true
}

export function addColumn(view, dir = 1) {
  const {state} = view
  const pos = state.selection.main.head
  const table = tableAt(state, pos)
  if (!table) return false
  const col = currentColumn(table, pos)
  const changes = table.rows.map((row, i) => {
    const pipes = row.pipes
    const lead = row.line.text.trimStart().startsWith("|") ? 1 : 0
    const pipeIndex = dir > 0 ? col + lead : col + lead - 1
    const insert = i === 1 ? " --- |" : "  |"
    // Rows without outer pipes get one, or the new cell would merge into the edge.
    if (pipeIndex < 0) return {from: row.line.from + /^\s*/.exec(row.line.text)[0].length, insert: "|" + insert + " "}
    if (pipeIndex >= pipes.length) return {from: row.line.to, insert: " |" + insert}
    return {from: row.line.from + pipes[pipeIndex] + 1, insert}
  })
  view.dispatch({changes, userEvent: "input.table"})
  return true
}

function tableEnter(view) {
  const {state} = view
  const pos = state.selection.main.head
  const table = tableAt(state, pos)
  if (!table) return false
  const lineNo = state.doc.lineAt(pos).number
  const col = currentColumn(table, pos)
  if (lineNo === table.last) return addRow(view, 1)
  let next = lineNo - table.first + 1
  if (next === 1) next = 2 // skip the --- row
  if (next >= table.rows.length) return addRow(view, 1)
  const cells = cellRanges(table.rows[next])
  const c = cells[Math.min(col, cells.length - 1)]
  view.dispatch({selection: {anchor: c.to}, scrollIntoView: true})
  return true
}

function tableShiftEnter(view) {
  const {state} = view
  const pos = state.selection.main.head
  const table = tableAt(state, pos)
  if (!table) return false
  const lineNo = state.doc.lineAt(pos).number
  if (lineNo === table.first) {
    const before = table.first > 1 ? state.doc.line(table.first - 1) : null
    if (!before) view.dispatch({changes: {from: 0, insert: "\n"}, selection: {anchor: 0}})
    else view.dispatch({selection: {anchor: before.to}})
    return true
  }
  const col = currentColumn(table, pos)
  let up = lineNo - table.first - 1
  if (up === 1) up = 0 // skip the --- row
  const cells = cellRanges(table.rows[up])
  view.dispatch({selection: {anchor: cells[Math.min(col, cells.length - 1)].to}, scrollIntoView: true})
  return true
}

function tableBreak(view) {
  if (!tableAt(view.state, view.state.selection.main.head)) return false
  view.dispatch(view.state.replaceSelection("<br>"))
  return true
}

export function insertTable(view) {
  const {state} = view
  const line = state.doc.lineAt(state.selection.main.head)
  const lead = line.text.trim() === "" ? "" : "\n\n"
  const at = line.text.trim() === "" ? line.from : line.to
  const text = lead + "|  |  |\n| --- | --- |\n|  |  |\n"
  view.dispatch({changes: {from: at, to: line.text.trim() === "" ? line.to : at, insert: text},
                 selection: {anchor: at + lead.length + 2}, scrollIntoView: true, userEvent: "input.table"})
  return true
}

export function insertDivider(view) {
  const {state} = view
  const line = state.doc.lineAt(state.selection.main.head)
  // A blank line first, or "---" would turn the line above into a heading.
  const text = line.text.trim() === "" ? "---\n" : "\n\n---\n"
  const at = line.text.trim() === "" ? line.from : line.to
  view.dispatch({changes: {from: at, to: line.text.trim() === "" ? line.to : at, insert: text},
                 selection: {anchor: at + text.length}, scrollIntoView: true, userEvent: "input.format"})
  return true
}

// ⌘K with text and address from the native dialog.
export function applyLink(view, {text = "", url = ""} = {}) {
  const {from, to} = view.state.selection.main
  const label = text || view.state.sliceDoc(from, to) || url
  const insert = url ? `[${label}](${/\s/.test(url) ? `<${url}>` : url})` : label
  view.dispatch({changes: {from, to, insert}, selection: {anchor: from + insert.length}, scrollIntoView: true, userEvent: "input.format"})
  return true
}

// What ⌘K starts from: the link under the cursor, or the selected text.
export function linkContext(view) {
  const {state} = view
  const {from, to} = state.selection.main
  const line = state.doc.lineAt(from)
  const re = /\[([^\]\n]*)\]\(\s*<?([^)>\s]*)>?\s*\)/g
  let m
  while ((m = re.exec(line.text))) {
    const a = line.from + m.index, b = a + m[0].length
    if (from >= a && to <= b) {
      view.dispatch({selection: {anchor: a, head: b}})
      return {text: m[1], url: m[2]}
    }
  }
  const text = state.sliceDoc(from, to)
  return /^(https?:\/\/|www\.)\S+$/.test(text) ? {text: "", url: text} : {text, url: ""}
}

export const notesCommands = {
  title: setStyle("h1"), heading: setStyle("h2"), subheading: setStyle("h3"),
  body: setStyle("body"), mono: toggleMono,
  bullet: setStyle("bullet"), dash: setStyle("dash"), number: setStyle("number"),
  checklist: setStyle("checklist"), quote: toggleQuote,
  toggleCheck, checkAll, uncheckAll, moveCheckedDown, deleteChecked,
  underline: toggleWrapPair("<u>", "</u>"), highlight: toggleWrap("=="),
  indent: (v) => indentItem(v) || true, outdent: (v) => outdentItem(v) || true,
  moveUp: moveLineUp, moveDown: moveLineDown,
  table: insertTable, divider: insertDivider,
  rowBelow: (v) => addRow(v, 1), rowAbove: (v) => addRow(v, -1),
  columnRight: (v) => addColumn(v, 1), columnLeft: (v) => addColumn(v, -1),
  applyLink, linkContext,
  sortChecklist: (v) => sortChecklistAt(v, v.state.selection.main.head),
}
for (let level = 1; level <= 6; level++) notesCommands["heading" + level] = setStyle("h" + level)
// h0…h6 (⌘0…⌘6): heading levels, 0 = body text.
for (let level = 0; level <= 6; level++) notesCommands["h" + level] = setStyle(level ? "h" + level : "body")

export const notesKeymap = [
  ...[0, 1, 2, 3, 4, 5, 6].map((level) => ({key: `Mod-${level}`, run: notesCommands["h" + level]})),
  {key: "Tab", run: tab},
  {key: "Shift-Tab", run: shiftTab},
  {key: "Enter", run: tableEnter},
  {key: "Shift-Enter", run: (v) => tableShiftEnter(v) || softBreak(v) || insertNewlineAndIndent(v)},
  {key: "Alt-Enter", run: tableBreak},
  {key: "Alt-Tab", run: (v) => { v.dispatch(v.state.replaceSelection("\t")); return true }},
  {key: "Mod-Alt-ArrowDown", run: (v) => addRow(v, 1)},
  {key: "Mod-Alt-ArrowUp", run: (v) => addRow(v, -1)},
  {key: "Mod-Alt-ArrowRight", run: (v) => addColumn(v, 1)},
  {key: "Mod-Alt-ArrowLeft", run: (v) => addColumn(v, -1)},
]
