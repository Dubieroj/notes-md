// Standalone HTML for "Export → HTML / PDF".
import {notesMarkdownIt} from "./mdit.js"
import {highlightCode, classHighlighter} from "@lezer/highlight"
import {LanguageDescription} from "@codemirror/language"
import {languages} from "@codemirror/language-data"
import {localPath} from "./ctx.js"
import tokensCss from "./tokens.css"
import exportCss from "./export.css"

const escapeHTML = (s) => s.replace(/[&<>"]/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"})[c])

function highlight(code, parser) {
  let out = ""
  highlightCode(
    code,
    parser.parse(code),
    classHighlighter,
    (text, classes) => { out += classes ? `<span class="${classes}">${escapeHTML(text)}</span>` : escapeHTML(text) },
    () => { out += "\n" },
  )
  return out
}

// fileImages: rewrite local images to absolute file:// URLs (for PDF rendering).
export async function exportHTML(text, {title = "", fileImages = false} = {}) {
  const parsers = new Map()
  for (const m of text.matchAll(/^[ \t>]*(?:```+|~~~+)[ \t]*([^\s`{]+)/gm)) {
    const name = m[1].toLowerCase()
    if (parsers.has(name)) continue
    const desc = LanguageDescription.matchLanguageName(languages, name, true)
    let parser = null
    if (desc) try { parser = (await desc.load()).language.parser } catch {}
    parsers.set(name, parser)
  }

  const md = notesMarkdownIt({
    html: true,
    highlight: (code, lang) => {
      const parser = parsers.get((lang || "").toLowerCase())
      return parser ? highlight(code, parser) : ""
    },
  })
  const fileURL = (src) => {
    const path = localPath(src)
    return path ? "file://" + path.split("/").map(encodeURIComponent).join("/") : src
  }
  if (fileImages) {
    const image = md.renderer.rules.image
    md.renderer.rules.image = (tokens, idx, options, env, self) => {
      tokens[idx].attrSet("src", fileURL(tokens[idx].attrGet("src") || ""))
      return image(tokens, idx, options, env, self)
    }
  }
  let body = md.render(text)
  // Pictures resized in Перо are <img> tags: their paths need the same treatment.
  if (fileImages) body = body.replace(/(<img\s[^>]*?src=")([^"]+)(")/gi, (m, a, src, b) => a + fileURL(src) + b)

  return `<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHTML(title)}</title>
<style>
${exportCss}
${tokensCss}
</style>
</head>
<body>
<article class="markdown">
${body}</article>
</body>
</html>
`
}

// HTML for the clipboard: the selection rendered, no page around it.
export function exportFragment(text) {
  return notesMarkdownIt().render(text)
}
