import {EditorView} from "@codemirror/view"
import {syntaxHighlighting} from "@codemirror/language"
import {classHighlighter, tagHighlighter, tags as t} from "@lezer/highlight"
import {highlightTag, hashtagTag} from "./syntax.js"

const textFont = '-apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif'
const monoFont = 'ui-monospace, "SF Mono", Menlo, monospace'

export const editorTheme = EditorView.theme({
  "&": {height: "100%", backgroundColor: "var(--bg)", color: "var(--text)"},
  "&.cm-focused": {outline: "none"},
  ".cm-scroller": {fontFamily: textFont, fontSize: "calc(var(--base-size, 16.5px) * var(--zoom, 1))", lineHeight: "var(--line, 1.7)"},
  ".cm-content": {
    maxWidth: "46rem",
    margin: "0 auto",
    padding: "2.5rem 2rem 40vh",
    caretColor: "var(--accent)",
  },
  "&.cm-source .cm-scroller": {fontFamily: monoFont, fontSize: "calc(14px * var(--zoom, 1))", lineHeight: "1.6"},
  "&.cm-source .cm-content": {maxWidth: "52rem"},
  ".cm-line": {padding: "0"},
  ".cm-cursor, .cm-dropCursor": {borderLeftColor: "var(--accent)", borderLeftWidth: "2px"},
  "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground, ::selection":
    {backgroundColor: "var(--selection) !important"},
  ".cm-searchMatch": {backgroundColor: "rgba(230, 180, 60, 0.3)", borderRadius: "2px"},
  ".cm-searchMatch.cm-searchMatch-selected": {backgroundColor: "rgba(230, 150, 40, 0.55)"},
  ".cm-panels": {backgroundColor: "var(--code-bg)", color: "var(--text)", fontFamily: textFont, fontSize: "13px"},
  ".cm-panels.cm-panels-top": {borderBottom: "1px solid var(--rule)"},
  ".cm-panel.cm-search": {padding: "8px 12px"},
  ".cm-panel.cm-search input, .cm-panel.cm-search button, .cm-panel.cm-search label": {fontSize: "13px"},
  ".cm-textfield": {
    backgroundColor: "var(--bg)", color: "var(--text)", border: "1px solid var(--rule)",
    borderRadius: "5px", padding: "3px 6px",
  },
  ".cm-button": {
    backgroundImage: "none", backgroundColor: "var(--bg)", color: "var(--text)",
    border: "1px solid var(--rule)", borderRadius: "5px", padding: "2px 9px",
  },
  ".cm-panel.cm-search [name=close]": {color: "var(--muted)", fontSize: "18px", right: "8px"},
})

// Markdown markup characters get a class so revealed markup can be tinted.
const markdownTags = tagHighlighter([
  {tag: t.processingInstruction, class: "tok-markup"},
  {tag: t.heading, class: "tok-heading"},
  {tag: t.emphasis, class: "tok-emphasis"},
  {tag: t.strong, class: "tok-strong"},
  {tag: t.strikethrough, class: "tok-strikethrough"},
  {tag: t.monospace, class: "tok-mono"},
  {tag: t.quote, class: "tok-quote"},
  {tag: t.url, class: "tok-url"},
  {tag: t.contentSeparator, class: "tok-markup"},
  {tag: highlightTag, class: "tok-highlight"},
  {tag: hashtagTag, class: "tok-hashtag"},
])

export const highlighting = [syntaxHighlighting(markdownTags), syntaxHighlighting(classHighlighter)]
