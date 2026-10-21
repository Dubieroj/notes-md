// Editor page: CodeMirror 6 with live preview, driven by the native shell
// through window.pero and window.webkit.messageHandlers.pero.
// One page serves every note of a window: switching notes swaps the editor state,
// and each note keeps its own undo history and scroll position.
import {EditorState, Compartment, Annotation} from "@codemirror/state"
import {EditorView, keymap, drawSelection, dropCursor, placeholder} from "@codemirror/view"
import {history, historyKeymap, defaultKeymap, undo, redo, selectAll} from "@codemirror/commands"
import {search, searchKeymap, openSearchPanel} from "@codemirror/search"
import {markdown, commonmarkLanguage} from "@codemirror/lang-markdown"
import {GFM} from "@lezer/markdown"
import {languages} from "@codemirror/language-data"
import {ctx, post} from "./ctx.js"
import {livePreview, focusTracking, headerField, setHeader} from "./livepreview.js"
import {editorTheme, highlighting} from "./theme.js"
import {formatKeymap, toggleWrap, insertLink} from "./format.js"
import {notesCommands, notesKeymap} from "./notes.js"
import {notesSyntax} from "./syntax.js"
import {statsLabel} from "./stats.js"
import {headings, currentHeading} from "./outline.js"
import {exportHTML} from "./export.js"
import {phrases} from "./phrases.js"
import {pasteAndCopy} from "./clipboard.js"
import {completion} from "./complete.js"
import {htmlToMarkdown} from "./htmlmd.js"
import {setLang, getLang, t} from "./i18n.js"

// ⌘/ switches to source mode in the app menu, so it is not "toggle comment" here.
const baseKeymap = defaultKeymap.filter((binding) => binding.key !== "Mod-/")

const External = Annotation.define() // changes that came from disk, not from typing

const mode = new Compartment()
const editable = new Compartment()
let currentMode = "live"
let readOnly = false
const modeExtension = (m) =>
  m === "source"
    ? EditorView.editorAttributes.of({class: "cm-source"})
    : [livePreview, EditorView.editorAttributes.of({class: "cm-live"})]
const editableExtension = (ro) => [EditorState.readOnly.of(ro), EditorView.editable.of(!ro)]
// The placeholder and CodeMirror's own panels follow the interface language, which
// arrives with configure() after the first state exists. English needs no phrases.
const language = new Compartment()
const languageExtension = () => [
  placeholder(t("Начните писать…")),
  getLang() === "ru" ? EditorState.phrases.of(phrases) : [],
]
let currentLanguage = languageExtension()

// ---------- debounced side panels ----------

let outline = []
let lastCurrent = -2
let outlineTimer = 0, statsTimer = 0

function sendOutline() {
  outline = headings(view.state)
  lastCurrent = -2
  post({type: "outline", items: outline})
  sendCurrent()
}

function sendCurrent() {
  const top = view.lineBlockAtHeight(view.scrollDOM.scrollTop + 8).from
  const index = currentHeading(outline, top)
  if (index !== lastCurrent) {
    lastCurrent = index
    post({type: "current", index})
  }
}

const statsEl = document.getElementById("stats")
const updateStats = () => { statsEl.textContent = statsLabel(view.state) }

// The note the editor shows. Edits carry it, so an edit still in flight while the
// user switches notes can never land in the next note.
let currentKey = null

// Every edit goes to the native side right away, so its copy of the text is
// always current and saving never has to wait for the page.
const listener = EditorView.updateListener.of((u) => {
  for (const tr of u.transactions) {
    if (!tr.docChanged || tr.annotation(External)) continue
    const changes = []
    tr.changes.iterChanges((fromA, toA, fromB, toB, inserted) => changes.push([fromB, toA - fromA, inserted.toString()]))
    post({type: "edit", key: currentKey, changes, length: tr.newDoc.length})
  }
  if (u.docChanged) {
    clearTimeout(outlineTimer)
    outlineTimer = setTimeout(sendOutline, 250)
  }
  if (u.docChanged || u.selectionSet) {
    clearTimeout(statsTimer)
    statsTimer = setTimeout(updateStats, 120)
  }
})

// ---------- state ----------

function makeState(text) {
  return EditorState.create({
    doc: text,
    extensions: [
      EditorState.lineSeparator.of("\n"), // a lone \r stays text, so files round-trip byte for byte
      history(),
      drawSelection(),
      dropCursor(),
      EditorView.lineWrapping,
      language.of(currentLanguage),
      EditorView.contentAttributes.of({spellcheck: "true", autocorrect: "off", autocapitalize: "off"}),
      markdown({base: commonmarkLanguage, extensions: [GFM, notesSyntax], codeLanguages: languages, completeHTMLTags: false}),
      highlighting,
      editorTheme,
      search({top: true}),
      completion,
      keymap.of([...notesKeymap, ...formatKeymap, ...searchKeymap, ...historyKeymap, ...baseKeymap]),
      focusTracking,
      headerField,
      pasteAndCopy,
      mode.of(modeExtension(currentMode)),
      editable.of(editableExtension(readOnly)),
      listener,
    ],
  })
}

const view = new EditorView({state: makeState(""), parent: document.getElementById("editor")})

let scrollQueued = false
view.scrollDOM.addEventListener("scroll", () => {
  if (scrollQueued) return
  scrollQueued = true
  requestAnimationFrame(() => { scrollQueued = false; sendCurrent() })
})

// Recent notes keep their state (undo history, selection, scroll) while the page lives.
const cache = new Map()
const cacheLimit = 20

function stash() {
  if (currentKey == null) return
  cache.delete(currentKey)
  cache.set(currentKey, {state: view.state, scroll: view.scrollDOM.scrollTop})
  while (cache.size > cacheLimit) cache.delete(cache.keys().next().value)
}

// ---------- API for the native shell ----------

const commands = {
  bold: toggleWrap("**"),
  italic: toggleWrap("*"),
  code: toggleWrap("`"),
  strike: toggleWrap("~~"),
  link: insertLink,
  undo, redo, selectAll,
  find: openSearchPanel,
  ...notesCommands,
}

// Replace the document but keep cursor, scroll and undo history: only the
// differing middle part is swapped (used when the file changes on disk).
function patch(text) {
  const cur = view.state.doc.toString()
  if (cur === text) return
  let start = 0
  const max = Math.min(cur.length, text.length)
  while (start < max && cur.charCodeAt(start) === text.charCodeAt(start)) start++
  let endA = cur.length, endB = text.length
  while (endA > start && endB > start && cur.charCodeAt(endA - 1) === text.charCodeAt(endB - 1)) { endA--; endB-- }
  view.dispatch({changes: {from: start, to: endA, insert: text.slice(start, endB)}, annotations: External.of(true)})
}

// A state from the cache may predate a mode or language switch: bring it up to date.
function refreshConfig(header) {
  view.dispatch({effects: [
    mode.reconfigure(modeExtension(currentMode)),
    editable.reconfigure(editableExtension(readOnly)),
    language.reconfigure(currentLanguage),
    setHeader.of(header ?? ""),
  ]})
}

window.pero = {
  configure(options = {}) {
    Object.assign(ctx, options)
    document.body.classList.toggle("notes", !!ctx.notes)
    document.body.classList.toggle("show-stats", !!ctx.showStats)
    if (options.zoom) document.documentElement.style.setProperty("--zoom", String(options.zoom))
    if (options.lang && options.lang !== getLang()) {
      setLang(options.lang)
      currentLanguage = languageExtension()
      view.dispatch({effects: language.reconfigure(currentLanguage)})
      updateStats()
    }
    view.requestMeasure()
  },
  load(text, {baseDir = null, keepView = false, key = null, header = null, readOnly: ro = false, focus = false} = {}) {
    ctx.baseDir = baseDir
    readOnly = ro
    if (keepView && key === currentKey) {
      patch(text)
      refreshConfig(header)
    } else {
      stash()
      currentKey = key
      const cached = key != null ? cache.get(key) : null
      if (cached && cached.state.doc.toString() === text) {
        view.setState(cached.state)
        refreshConfig(header)
        view.scrollDOM.scrollTop = cached.scroll
      } else {
        view.setState(makeState(text))
        refreshConfig(header)
        view.scrollDOM.scrollTop = 0
      }
    }
    sendOutline()
    updateStats()
    if (focus) view.focus()
  },
  // A note being locked: the next load must not stash its state again.
  forget(key) {
    cache.delete(key)
    if (currentKey === key) currentKey = null
  },
  rekey(from, to) {
    if (currentKey === from) currentKey = to
    if (cache.has(from)) { cache.set(to, cache.get(from)); cache.delete(from) }
  },
  getText: () => view.state.doc.toString(),
  setBaseDir(dir) { ctx.baseDir = dir },
  setHeader(text) { view.dispatch({effects: setHeader.of(text ?? "")}) },
  setMode(m) {
    currentMode = m === "source" ? "source" : "live"
    view.dispatch({effects: mode.reconfigure(modeExtension(currentMode))})
    return currentMode
  },
  command(name, arg) {
    const run = commands[name]
    if (!run) return false
    const result = run(view, arg)
    view.focus()
    return result !== false
  },
  // Replaces the selection with text (attachments, pasted content from the shell).
  insert(text, {select = false} = {}) {
    const {from, to} = view.state.selection.main
    view.dispatch({
      changes: {from, to, insert: text},
      selection: select ? {anchor: from, head: from + text.length} : {anchor: from + text.length},
      scrollIntoView: true, userEvent: "input.paste",
    })
    view.focus()
  },
  selection() {
    const {from, to} = view.state.selection.main
    return {from, to, text: view.state.sliceDoc(from, to)}
  },
  reveal(pos) {
    pos = Math.min(pos, view.state.doc.length)
    view.dispatch({selection: {anchor: pos}, effects: EditorView.scrollIntoView(pos, {y: "start", yMargin: 24})})
    view.focus()
  },
  focus: () => view.focus(),
  blur: () => view.contentDOM.blur(),
  exportHTML: (options) => exportHTML(view.state.doc.toString(), options),
  // Any note's text, with its own folder for relative pictures (batch export, printing).
  async renderHTML(text, options = {}) {
    const saved = ctx.baseDir
    if ("baseDir" in options) ctx.baseDir = options.baseDir
    try { return await exportHTML(text, options) } finally { ctx.baseDir = saved }
  },
  htmlToMarkdown: (html) => htmlToMarkdown(html),
  linkContext: () => notesCommands.linkContext(view),
  view, // for debugging from Web Inspector
}

post({type: "ready"})
