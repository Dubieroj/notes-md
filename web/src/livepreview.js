// Live preview: the document stays plain Markdown, decorations make it look
// formatted. Markup is hidden everywhere except the element under the cursor.
import {ViewPlugin, Decoration, WidgetType, EditorView, gutter, GutterMarker} from "@codemirror/view"
import {StateField, StateEffect} from "@codemirror/state"
import {syntaxTree, codeFolding, foldable, foldEffect, unfoldEffect, foldedRanges} from "@codemirror/language"
import {ctx, resolveImageURL, openLink, localPath, post} from "./ctx.js"
import {renderInline} from "./inline.js"
import {sortChecklistAt} from "./notes.js"

// Markup is revealed only while the editor has focus, so a freshly opened
// document (cursor at 0) looks fully rendered.
export const setReveal = StateEffect.define()
const revealField = StateField.define({
  create: () => false,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setReveal)) value = e.value
    return value
  },
})

function touches(state, from, to) {
  if (!state.field(revealField)) return false
  for (const r of state.selection.ranges) if (r.from <= to && r.to >= from) return true
  return false
}

function lineTouched(state, pos) {
  const line = state.doc.lineAt(pos)
  return touches(state, line.from, line.to)
}

const hidden = Decoration.replace({})
const lineCache = new Map()
function lineDeco(cls) {
  let d = lineCache.get(cls)
  if (!d) lineCache.set(cls, (d = Decoration.line({class: cls})))
  return d
}
const markCache = new Map()
function markDeco(cls) {
  let d = markCache.get(cls)
  if (!d) markCache.set(cls, (d = Decoration.mark({class: cls})))
  return d
}

// ---------- the date above the note (as in Notes) ----------

export const setHeader = StateEffect.define()

class HeaderWidget extends WidgetType {
  constructor(text) { super(); this.text = text }
  eq(other) { return other.text === this.text }
  toDOM() {
    const div = document.createElement("div")
    div.className = "cm-note-date"
    div.textContent = this.text
    return div
  }
  ignoreEvent() { return true }
}

export const headerField = StateField.define({
  create: () => ({text: "", decos: Decoration.none}),
  update(value, tr) {
    for (const e of tr.effects) {
      if (e.is(setHeader)) {
        const text = e.value
        value = {text, decos: text ? Decoration.set([Decoration.widget({widget: new HeaderWidget(text), block: true, side: -1}).range(0)]) : Decoration.none}
      }
    }
    return value
  },
  provide: (f) => EditorView.decorations.from(f, (v) => v.decos),
})

// ---------- widgets ----------

class BulletWidget extends WidgetType {
  constructor(depth, dash) { super(); this.depth = depth; this.dash = dash }
  eq(other) { return other.depth === this.depth && other.dash === this.dash }
  toDOM() {
    const span = document.createElement("span")
    span.className = "cm-bullet" + (this.dash ? " cm-dash" : "")
    span.textContent = this.dash ? "–" : ["•", "◦", "▪"][this.depth % 3]
    return span
  }
  ignoreEvent() { return false }
}

class TaskWidget extends WidgetType {
  constructor(checked) { super(); this.checked = checked }
  eq(other) { return other.checked === this.checked }
  toDOM(view) {
    const box = document.createElement("span")
    box.className = "cm-task-box" + (this.checked ? " cm-task-checked" : "")
    box.setAttribute("role", "checkbox")
    box.setAttribute("aria-checked", String(this.checked))
    box.setAttribute("aria-label", this.checked ? "Выполнено" : "Не выполнено")
    box.addEventListener("mousedown", (e) => {
      e.preventDefault()
      if (view.state.readOnly) return
      toggleTask(view, view.posAtDOM(box))
    })
    return box
  }
  ignoreEvent() { return true }
}

function toggleTask(view, pos) {
  const line = view.state.doc.lineAt(pos)
  const m = /\[([ xX])\]/.exec(line.text.slice(pos - line.from))
  if (!m) return
  const at = pos + m.index + 1
  view.dispatch({
    changes: {from: at, to: at + 1, insert: m[1] === " " ? "x" : " "},
    userEvent: "input.toggle",
  })
  // Notes moves checked items to the bottom when that setting is on (unless the
  // text or the shown note changed meanwhile).
  const doc = view.state.doc
  if (ctx.autoSortChecked) setTimeout(() => { if (view.state.doc === doc) sortChecklistAt(view, at) }, 350)
}

// Turns a picture into <img … width="N"> after it was resized with the handle.
function resizeImage(view, wrap, width) {
  const pos = view.posAtDOM(wrap)
  let node = syntaxTree(view.state).resolveInner(pos, 1)
  while (node && node.name !== "Image" && node.name !== "HTMLTag" && node.name !== "HTMLBlock") node = node.parent
  if (!node) return
  const text = view.state.sliceDoc(node.from, node.to)
  let src, alt, title = ""
  if (node.name === "Image") {
    const marks = childrenNamed(node, "LinkMark"), url = node.getChild("URL"), t = node.getChild("LinkTitle")
    if (!url || marks.length < 2) return
    alt = view.state.sliceDoc(marks[0].to, marks[1].from).replace(/\s+/g, " ")
    src = view.state.sliceDoc(url.from, url.to).replace(/^<|>$/g, "")
    if (t) title = view.state.sliceDoc(t.from + 1, t.to - 1)
  } else {
    src = (/src\s*=\s*"([^"]*)"/i.exec(text) || [])[1]
    alt = (/alt\s*=\s*"([^"]*)"/i.exec(text) || [])[1] || ""
    title = (/title\s*=\s*"([^"]*)"/i.exec(text) || [])[1] || ""
    if (!src) return
  }
  const esc = (s) => s.replace(/"/g, "&quot;")
  const insert = `<img src="${esc(src)}" width="${Math.round(width)}"${alt ? ` alt="${esc(alt)}"` : ""}${title ? ` title="${esc(title)}"` : ""}>`
  view.dispatch({changes: {from: node.from, to: node.to, insert}, userEvent: "input.resize"})
}

class ImageWidget extends WidgetType {
  constructor(src, alt, width) { super(); this.src = src; this.alt = alt; this.width = width }
  eq(other) { return other.src === this.src && other.alt === this.alt && other.width === this.width }
  toDOM(view) {
    const wrap = document.createElement("span")
    wrap.className = "cm-image"
    const img = document.createElement("img")
    img.src = resolveImageURL(this.src)
    img.alt = this.alt
    if (this.alt) img.title = this.alt
    if (this.width) img.style.width = this.width + "px"
    img.onload = () => view.requestMeasure()
    img.onerror = () => {
      wrap.className = "cm-image cm-image-broken"
      wrap.textContent = (/^https?:/i.test(this.src) ? "Картинка из интернета не загружается: " : "Нет картинки: ") + (this.alt || this.src)
      view.requestMeasure()
    }
    wrap.appendChild(img)
    if (!view.state.readOnly) {
      const handle = document.createElement("span")
      handle.className = "cm-image-handle"
      handle.title = "Изменить размер"
      handle.addEventListener("mousedown", (e) => {
        e.preventDefault()
        e.stopPropagation()
        const startX = e.clientX, startW = img.getBoundingClientRect().width
        const move = (ev) => { img.style.width = Math.max(40, startW + ev.clientX - startX) + "px" }
        const up = () => {
          window.removeEventListener("mousemove", move)
          window.removeEventListener("mouseup", up)
          resizeImage(view, wrap, img.getBoundingClientRect().width)
        }
        window.addEventListener("mousemove", move)
        window.addEventListener("mouseup", up)
      })
      wrap.appendChild(handle)
    }
    return wrap
  }
  ignoreEvent(e) { return e.type === "mousedown" && e.target.classList?.contains("cm-image-handle") }
}

const fileIcons = {pdf: "📄", m4a: "🎙", mp3: "🎵", wav: "🎙", zip: "🗜", doc: "📝", docx: "📝", pages: "📝",
  xls: "📊", xlsx: "📊", numbers: "📊", key: "📽", pptx: "📽", txt: "📃", rtf: "📃"}

class FileWidget extends WidgetType {
  constructor(label, href) { super(); this.label = label; this.href = href }
  eq(other) { return other.label === this.label && other.href === this.href }
  toDOM() {
    const card = document.createElement("span")
    card.className = "cm-file"
    const ext = (/\.([a-z0-9]+)(?:[?#].*)?$/i.exec(this.href) || [])[1]?.toLowerCase() || ""
    const icon = document.createElement("span")
    icon.className = "cm-file-icon"
    icon.textContent = fileIcons[ext] || "📎"
    const name = document.createElement("span")
    name.className = "cm-file-name"
    name.textContent = this.label || decodeURIComponent(this.href.split("/").pop())
    card.append(icon, name)
    card.title = "Открыть вложение"
    card.addEventListener("mousedown", (e) => { e.preventDefault(); openLink(this.href) })
    return card
  }
  ignoreEvent() { return true }
}

class RuleWidget extends WidgetType {
  eq() { return true }
  toDOM() {
    const span = document.createElement("span")
    span.className = "cm-hr"
    return span
  }
  ignoreEvent() { return false }
}
const ruleWidget = new RuleWidget()

// ---------- inline and block decorations (visible part only) ----------

function childrenNamed(node, name) {
  const out = []
  for (let c = node.firstChild; c; c = c.nextSibling) if (c.name === name) out.push(c)
  return out
}

function listDepth(node) {
  let depth = 0
  for (let p = node.parent; p; p = p.parent) if (p.name === "BulletList" || p.name === "OrderedList") depth++
  return Math.max(0, depth - 1)
}

function forEachLine(state, from, to, vp, fn) {
  const start = Math.max(from, vp.from), end = Math.min(to, vp.to)
  if (start > end) return
  for (let pos = state.doc.lineAt(start).from; pos <= end;) {
    const line = state.doc.lineAt(pos)
    fn(line)
    pos = line.to + 1
  }
}

// The first non-blank line is the note's title (Notes styles it whatever it is).
function titleLine(state) {
  let n = 1
  const doc = state.doc
  if (doc.line(1).text === "---") {
    for (let i = 2; i <= Math.min(doc.lines, 200); i++) {
      const t = doc.line(i).text
      if (t === "---" || t === "...") { n = i + 1; break }
    }
  }
  for (const end = Math.min(doc.lines, n + 50); n <= end; n++) if (doc.line(n).text.trim() !== "") return doc.line(n)
  return null
}

const isLocalFile = (href) => {
  const path = localPath(href)
  return path !== null && !/\.(md|markdown|mdown|mkd|mkdn)$/i.test(path) && /\.[a-z0-9]+$/i.test(path)
}

const imgTag = /^<img\s[^>]*>$/i

function imageFromTag(text) {
  if (!imgTag.test(text.trim())) return null
  const src = (/src\s*=\s*"([^"]*)"/i.exec(text) || [])[1]
  if (!src) return null
  const width = Number((/width\s*=\s*"?(\d+)/i.exec(text) || [])[1]) || null
  const alt = (/alt\s*=\s*"([^"]*)"/i.exec(text) || [])[1] || ""
  return {src, width, alt}
}

function buildDecorations(view) {
  const {state} = view
  const vp = view.viewport
  const decos = []
  // Empty marks throw, and a plugin may not replace a line break: such markup stays plain text.
  const add = (deco, from, to = from) => {
    if (deco.point ? to > state.doc.lineAt(from).to : to <= from) return
    decos.push(deco.range(from, to))
  }

  if (ctx.notes) {
    const title = titleLine(state)
    if (title && title.from >= vp.from && title.from <= vp.to && !/^#{1,6}\s/.test(title.text)) add(lineDeco("cm-title"), title.from)
  }

  let openU = null // a <u> waiting for its </u> on the same line

  syntaxTree(state).iterate({
    from: vp.from,
    to: vp.to,
    enter(ref) {
      const node = ref.node
      const name = node.name

      if (name.startsWith("ATXHeading")) {
        const level = name.slice(-1)
        const line = state.doc.lineAt(node.from)
        add(lineDeco(`cm-h cm-h${level}`), line.from)
        if (!lineTouched(state, node.from)) {
          for (const mark of childrenNamed(node, "HeaderMark")) {
            if (mark.from === node.from) {
              if (mark.to === node.to) continue // empty heading: keep the #
              let end = mark.to
              while (end < line.to && /[ \t]/.test(state.sliceDoc(end, end + 1))) end++
              add(hidden, mark.from, end)
            } else {
              let start = mark.from
              while (start > node.from && /[ \t]/.test(state.sliceDoc(start - 1, start))) start--
              add(hidden, start, mark.to)
            }
          }
        }
        return
      }

      if (name.startsWith("SetextHeading")) {
        const level = name.slice(-1)
        const mark = node.getChild("HeaderMark")
        const touched = touches(state, node.from, node.to)
        forEachLine(state, node.from, node.to, vp, (line) => {
          if (mark && line.from <= mark.from && mark.from <= line.to)
            add(lineDeco(touched ? "cm-setext-mark" : "cm-setext-mark cm-setext-hidden"), line.from)
          else add(lineDeco(`cm-h cm-h${level}`), line.from)
        })
        return
      }

      switch (name) {
        case "Emphasis":
        case "StrongEmphasis":
        case "Strikethrough":
        case "Highlight":
        case "InlineCode": {
          if (name === "InlineCode") add(markDeco("cm-inline-code"), node.from, node.to)
          if (name === "Highlight") add(markDeco("cm-highlight"), node.from, node.to)
          if (!touches(state, node.from, node.to)) {
            for (let c = node.firstChild; c; c = c.nextSibling)
              if (/^(Emphasis|Strikethrough|Code|Highlight)Mark$/.test(c.name)) add(hidden, c.from, c.to)
          }
          return
        }

        case "WikiLink": {
          const marks = childrenNamed(node, "WikiMark")
          if (marks.length < 2) return false
          const inner = state.sliceDoc(marks[0].to, marks[1].from)
          const bar = inner.indexOf("|")
          const textFrom = bar >= 0 ? marks[0].to + bar + 1 : marks[0].to
          add(markDeco("cm-wiki"), textFrom, marks[1].from)
          if (!touches(state, node.from, node.to)) {
            add(hidden, marks[0].from, textFrom)
            add(hidden, marks[1].from, marks[1].to)
          }
          return false
        }

        case "Hashtag":
          add(markDeco("cm-hashtag"), node.from, node.to)
          return false

        case "HTMLTag": {
          const text = state.sliceDoc(node.from, node.to)
          const img = imageFromTag(text)
          if (img) {
            const widget = new ImageWidget(img.src, img.alt, img.width)
            if (!touches(state, node.from, node.to)) add(Decoration.replace({widget}), node.from, node.to)
            else add(Decoration.widget({widget, side: 1}), node.to)
            return false
          }
          if (/^<u>$/i.test(text)) openU = node
          else if (/^<\/u>$/i.test(text) && openU && state.doc.lineAt(openU.from).number === state.doc.lineAt(node.from).number) {
            add(markDeco("cm-underline"), openU.to, node.from)
            if (!touches(state, openU.from, node.to)) { add(hidden, openU.from, openU.to); add(hidden, node.from, node.to) }
            openU = null
          } else if (/^<br\s*\/?>$/i.test(text) && !touches(state, node.from, node.to)) {
            add(Decoration.replace({widget: new BreakWidget()}), node.from, node.to)
          }
          return false
        }

        case "HTMLBlock": {
          const text = state.sliceDoc(node.from, node.to)
          const img = imageFromTag(text)
          if (!img) return false
          const widget = new ImageWidget(img.src, img.alt, img.width)
          if (!touches(state, node.from, node.to)) add(Decoration.replace({widget}), node.from, node.to)
          else add(Decoration.widget({widget, side: 1}), node.to)
          return false
        }

        case "HardBreak": {
          const text = state.sliceDoc(node.from, node.to)
          if (text.startsWith("\\") && !lineTouched(state, node.from)) add(hidden, node.from, node.from + 1)
          return false
        }

        case "Link": {
          const marks = childrenNamed(node, "LinkMark")
          // A bare "[text]" is just brackets in prose, not a link.
          if (marks.length < 3 && !node.getChild("LinkLabel")) return
          const url = node.getChild("URL")
          const href = url ? state.sliceDoc(url.from, url.to) : ""
          if (href && isLocalFile(href) && marks.length >= 2 && !touches(state, node.from, node.to)) {
            const label = state.sliceDoc(marks[0].to, marks[1].from)
            add(Decoration.replace({widget: new FileWidget(label, href)}), node.from, node.to)
            return false
          }
          add(markDeco("cm-link"), marks[0].to, marks[1].from)
          if (!touches(state, node.from, node.to) && state.doc.lineAt(marks[1].from).to >= node.to) {
            add(hidden, marks[0].from, marks[0].to)
            add(hidden, marks[1].from, node.to)
          }
          return
        }

        case "Autolink": {
          const url = node.getChild("URL")
          if (url) add(markDeco("cm-link"), url.from, url.to)
          if (!touches(state, node.from, node.to))
            for (const m of childrenNamed(node, "LinkMark")) add(hidden, m.from, m.to)
          return false
        }

        case "URL": {
          const parent = node.parent?.name
          if (parent !== "Link" && parent !== "Image" && parent !== "Autolink" && parent !== "LinkReference")
            add(markDeco("cm-link"), node.from, node.to)
          return
        }

        case "Image": {
          const marks = childrenNamed(node, "LinkMark")
          const url = node.getChild("URL")
          if (!url || marks.length < 2) return false
          const alt = state.sliceDoc(marks[0].to, marks[1].from)
          const src = state.sliceDoc(url.from, url.to).replace(/^<|>$/g, "")
          // A PDF or sketch written as an image still shows as a picture or a card.
          const widget = /\.(pdf|m4a|mp3|wav)$/i.test(src) ? new FileWidget(alt, src) : new ImageWidget(src, alt, null)
          if (!touches(state, node.from, node.to)) add(Decoration.replace({widget}), node.from, node.to)
          else add(Decoration.widget({widget, side: 1}), node.to)
          return false
        }

        case "Blockquote":
          forEachLine(state, node.from, node.to, vp, (line) => add(lineDeco("cm-quote"), line.from))
          return

        case "QuoteMark":
          if (!lineTouched(state, node.from)) {
            let end = node.to
            if (state.sliceDoc(end, end + 1) === " ") end++
            add(hidden, node.from, end)
          }
          return

        case "ListMark": {
          const item = node.parent
          if (item?.getChild("Task")) return // drawn as a checkbox below
          if (item?.parent?.name === "BulletList") {
            const dash = state.sliceDoc(node.from, node.to) === "+"
            if (!touches(state, node.from, node.to))
              add(Decoration.replace({widget: new BulletWidget(listDepth(item), dash)}), node.from, node.to)
          } else {
            add(markDeco("cm-list-number"), node.from, node.to)
          }
          return
        }

        case "Task": {
          const marker = node.getChild("TaskMarker")
          const listMark = node.parent?.getChild("ListMark")
          if (!marker || !listMark) return
          const checked = /x/i.test(state.sliceDoc(marker.from, marker.to))
          if (checked && marker.to < node.to) add(markDeco("cm-task-done"), marker.to, node.to)
          if (!touches(state, listMark.from, marker.to))
            add(Decoration.replace({widget: new TaskWidget(checked)}), listMark.from, marker.to)
          return
        }

        case "HorizontalRule":
          if (!lineTouched(state, node.from)) add(Decoration.replace({widget: ruleWidget}), node.from, node.to)
          return false

        case "FencedCode": {
          const touched = touches(state, node.from, node.to)
          const marks = childrenNamed(node, "CodeMark")
          const first = state.doc.lineAt(node.from).number
          const closed = marks.length > 1
          const last = state.doc.lineAt(node.to).number
          forEachLine(state, node.from, node.to, vp, (line) => {
            let cls = "cm-codeblock"
            if (line.number === first) cls += " cm-codeblock-begin" + (touched ? "" : " cm-fence-quiet")
            if (line.number === last && closed) cls += " cm-codeblock-end" + (touched ? "" : " cm-fence-quiet")
            add(lineDeco(cls), line.from)
          })
          const info = node.getChild("CodeInfo")
          if (info) add(markDeco("cm-code-lang"), info.from, info.to)
          if (!touched) {
            if (marks[0]) add(hidden, marks[0].from, marks[0].to)
            if (closed) add(hidden, marks[marks.length - 1].from, marks[marks.length - 1].to)
          }
          return false
        }

        case "CodeBlock":
          forEachLine(state, node.from, node.to, vp, (line) => add(lineDeco("cm-codeblock cm-codeblock-indented"), line.from))
          return false

        case "Escape":
          if (!touches(state, node.from, node.to)) add(hidden, node.from, node.from + 1)
          return

        case "Table":
          return false // see tableField
      }
    },
  })
  return Decoration.set(decos, true)
}

class BreakWidget extends WidgetType {
  eq() { return true }
  toDOM() { return document.createElement("br") }
}

const previewPlugin = ViewPlugin.fromClass(
  class {
    constructor(view) { this.decorations = buildDecorations(view) }
    update(u) {
      if (
        u.docChanged || u.viewportChanged || u.selectionSet ||
        u.startState.field(revealField) !== u.state.field(revealField) ||
        syntaxTree(u.startState) !== syntaxTree(u.state)
      )
        this.decorations = buildDecorations(u.view)
    }
  },
  {decorations: (v) => v.decorations},
)

// ---------- tables (block widgets must come from state, not a plugin) ----------

function splitRow(text, lineFrom) {
  const cells = []
  let start = text.match(/^\s*\|?/)[0].length
  const cell = (a, b) => {
    const raw = text.slice(a, b)
    return {text: raw.trim().replace(/\\\|/g, "|"), pos: lineFrom + a + raw.match(/^\s*/)[0].length}
  }
  for (let i = start; i < text.length; i++) {
    if (text[i] === "\\") { i++; continue }
    if (text[i] === "|") { cells.push(cell(start, i)); start = i + 1 }
  }
  if (text.slice(start).trim() !== "") cells.push(cell(start, text.length))
  return cells
}

function parseTable(state, from, to) {
  const lines = []
  for (let pos = from; pos <= to;) {
    const line = state.doc.lineAt(pos)
    lines.push(line)
    pos = line.to + 1
  }
  const head = splitRow(lines[0].text, lines[0].from)
  const align = splitRow(lines[1].text, lines[1].from).map(({text}) => {
    const l = text.startsWith(":"), r = text.endsWith(":")
    return l && r ? "center" : r ? "right" : l ? "left" : ""
  })
  const cols = head.length
  const rows = lines.slice(2).map((line) => {
    const cells = splitRow(line.text, line.from).slice(0, cols)
    while (cells.length < cols) cells.push({text: "", pos: line.to})
    return cells
  })
  // Positions are stored relative to the table so the widget survives edits above it.
  const rel = (c) => ({text: c.text, offset: c.pos - from})
  return {align, head: head.map(rel), rows: rows.map((r) => r.map(rel))}
}

class TableWidget extends WidgetType {
  constructor(table) { super(); this.table = table; this.key = JSON.stringify(table) }
  eq(other) { return other.key === this.key }
  get estimatedHeight() { return (this.table.rows.length + 1) * 34 + 16 }
  toDOM(view) {
    const wrap = document.createElement("div")
    wrap.className = "cm-table-wrap"
    const table = document.createElement("table")
    const row = (cells, tag) => {
      const tr = document.createElement("tr")
      cells.forEach((c, i) => {
        const td = document.createElement(tag)
        td.innerHTML = renderInline(c.text)
        td.dataset.offset = c.offset
        if (this.table.align[i]) td.style.textAlign = this.table.align[i]
        tr.appendChild(td)
      })
      return tr
    }
    const thead = document.createElement("thead")
    thead.appendChild(row(this.table.head, "th"))
    const tbody = document.createElement("tbody")
    for (const r of this.table.rows) tbody.appendChild(row(r, "td"))
    table.append(thead, tbody)
    wrap.appendChild(table)
    wrap.addEventListener("mousedown", (e) => {
      e.preventDefault()
      const link = e.target.closest("a")
      if (link) return openLink(link.getAttribute("href"))
      const cell = e.target.closest("[data-offset]")
      const pos = view.posAtDOM(wrap) + (cell ? Number(cell.dataset.offset) : 0)
      view.dispatch({selection: {anchor: pos}})
      view.focus()
    })
    return wrap
  }
  ignoreEvent() { return true }
}

const containers = new Set(["Document", "Blockquote", "BulletList", "OrderedList", "ListItem"])

function buildTables(state) {
  const decos = []
  syntaxTree(state).iterate({
    enter(ref) {
      if (ref.name === "Table") {
        const first = state.doc.lineAt(ref.from), last = state.doc.lineAt(ref.to)
        const wholeLines = first.from === ref.from && last.to === ref.to && last.number - first.number >= 1
        if (wholeLines && !touches(state, ref.from, ref.to)) {
          const widget = new TableWidget(parseTable(state, ref.from, ref.to))
          decos.push(Decoration.replace({widget, block: true}).range(ref.from, ref.to))
        } else {
          for (let n = first.number; n <= last.number; n++) decos.push(lineDeco("cm-table-source").range(state.doc.line(n).from))
        }
        return false
      }
      return containers.has(ref.name)
    },
  })
  return Decoration.set(decos, true)
}

const tableField = StateField.define({
  create: (state) => buildTables(state),
  update(decos, tr) {
    if (
      tr.docChanged || tr.selection ||
      tr.startState.field(revealField) !== tr.state.field(revealField) ||
      syntaxTree(tr.startState) !== syntaxTree(tr.state)
    )
      return buildTables(tr.state)
    return decos
  },
  provide: (f) => EditorView.decorations.from(f),
})

// ---------- links: a click on a rendered link opens it, ⌘-click always ----------

function linkTarget(state, pos) {
  for (let node = syntaxTree(state).resolveInner(pos, 1); node; node = node.parent) {
    if (node.name === "WikiLink") {
      const inner = state.sliceDoc(node.from + 2, node.to - 2)
      const [target, section] = inner.split("|")[0].split("#")
      return {wiki: target.trim(), section: section?.trim() || null, from: node.from, to: node.to}
    }
    if (node.name === "Hashtag") return {tag: state.sliceDoc(node.from + 1, node.to), from: node.from, to: node.to}
    if (node.name === "URL") return {href: state.sliceDoc(node.from, node.to), from: node.from, to: node.to}
    if (node.name === "Link" || node.name === "Autolink" || node.name === "Image") {
      const url = node.getChild("URL")
      return url ? {href: state.sliceDoc(url.from, url.to), from: node.from, to: node.to} : null
    }
  }
  return null
}

const linkClicks = EditorView.domEventHandlers({
  mousedown(e, view) {
    if (e.button !== 0 || e.shiftKey || e.altKey) return false
    const pos = view.posAtCoords({x: e.clientX, y: e.clientY})
    if (pos == null) return false
    const target = linkTarget(view.state, pos)
    if (!target) return false
    // While the markup is shown the link is being edited: a click places the cursor.
    if (!e.metaKey && touches(view.state, target.from, target.to)) return false
    if (!e.metaKey && !e.target.closest?.(".cm-link, .cm-wiki, .cm-hashtag")) return false
    e.preventDefault()
    if (target.wiki != null) post({type: "openWiki", target: target.wiki, section: target.section, newWindow: e.metaKey})
    else if (target.tag != null) post({type: "openTag", tag: target.tag})
    else openLink(target.href)
    return true
  },
})

// ---------- folding sections under headings (Notes 15) ----------

class FoldMarker extends GutterMarker {
  constructor(open) { super(); this.open = open }
  eq(other) { return other.open === this.open }
  toDOM() {
    const span = document.createElement("span")
    span.className = "cm-fold-marker" + (this.open ? "" : " cm-folded")
    span.textContent = "›"
    span.title = this.open ? "Свернуть раздел" : "Развернуть раздел"
    return span
  }
}
const openMarker = new FoldMarker(true), closedMarker = new FoldMarker(false)

function headingFold(state, line) {
  const node = syntaxTree(state).resolveInner(line.from, 1)
  for (let n = node; n; n = n.parent) {
    if (/^(ATX|Setext)Heading/.test(n.name)) return foldable(state, line.from, line.to)
  }
  return null
}

function foldedAt(state, line) {
  let found = null
  foldedRanges(state).between(line.to, line.to + 1, (from, to) => { if (from === line.to) found = {from, to} })
  return found
}

const headingGutter = gutter({
  class: "cm-heading-gutter",
  lineMarker(view, block) {
    const line = view.state.doc.lineAt(block.from)
    if (!/^\s{0,3}#{1,6}\s/.test(line.text)) return null
    if (foldedAt(view.state, line)) return closedMarker
    return headingFold(view.state, line) ? openMarker : null
  },
  lineMarkerChange: (u) => u.docChanged || u.viewportChanged || u.transactions.some((tr) => tr.effects.some((e) => e.is(foldEffect) || e.is(unfoldEffect))),
  domEventHandlers: {
    mousedown(view, block) {
      const line = view.state.doc.lineAt(block.from)
      const folded = foldedAt(view.state, line)
      if (folded) { view.dispatch({effects: unfoldEffect.of(folded)}); return true }
      const range = headingFold(view.state, line)
      if (range) { view.dispatch({effects: foldEffect.of(range)}); return true }
      return false
    },
  },
})

const sectionFolding = codeFolding({
  placeholderDOM(view, onclick) {
    const span = document.createElement("span")
    span.className = "cm-foldPlaceholder"
    span.textContent = "…"
    span.title = "Развернуть раздел"
    span.onclick = onclick
    return span
  },
})

const revealOnFocus = EditorView.focusChangeEffect.of((state, focusing) => setReveal.of(focusing))

// revealField and the focus hook stay loaded in source mode too, so switching
// modes never loses the focus state.
export const focusTracking = [revealField, revealOnFocus, sectionFolding]
export const livePreview = [previewPlugin, tableField, linkClicks, headingGutter]
