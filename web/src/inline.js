// Inline Markdown → HTML for table cells shown inside the editor.
import {notesMarkdownIt} from "./mdit.js"
import {resolveImageURL} from "./ctx.js"

const md = notesMarkdownIt({resolveImage: resolveImageURL})
const defaultImage = md.renderer.rules.image

md.renderer.rules.image = (tokens, idx, options, env, self) => {
  const token = tokens[idx]
  token.attrSet("src", resolveImageURL(token.attrGet("src") || ""))
  return defaultImage(tokens, idx, options, env, self)
}

export function renderInline(text) {
  return md.renderInline(text)
}
