// Standalone renderer for Quick Look (JavaScriptCore, no DOM): Markdown → HTML page.
import {notesMarkdownIt} from "./mdit.js"
import tokensCss from "./tokens.css"
import exportCss from "./export.css"

const escapeHTML = (s) => s.replace(/[&<>"]/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"})[c])

// Pictures never load from the network: only data: URIs and paths (the shell attaches
// files next to the note) keep their src. URL parsing drops spaces and controls, so the check does too.
function offline(src) {
  const s = src.replace(/[\x00-\x20]/g, "")
  return /^data:/i.test(s) || !/^([a-z][a-z0-9+.-]*:|[\\/]{2})/i.test(s) ? src : ""
}

// Raw HTML stays off: a previewed file may come from anywhere.
export function page(text, title = "") {
  const md = notesMarkdownIt({html: false, resolveImage: offline})
  const image = md.renderer.rules.image
  md.renderer.rules.image = (tokens, idx, ...rest) => {
    tokens[idx].attrSet("src", offline(tokens[idx].attrGet("src") || ""))
    return image(tokens, idx, ...rest)
  }
  const body = md.render(text)
  return `<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>${escapeHTML(title)}</title>
<style>${exportCss}${tokensCss}</style></head><body><article class="markdown">${body}</article></body></html>`
}
