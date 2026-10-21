// markdown-it set up for Перо: task lists, ==highlight==, [[wiki links]] and the few
// HTML tags notes use (<u>, <br>, <img>) even where raw HTML is off.
import MarkdownIt from "markdown-it"

const escapeHTML = (s) => s.replace(/[&<>"]/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"})[c])

// "- [ ] text" / "- [x] text" → drawn checkboxes, same look as in the editor.
function taskLists(md) {
  md.core.ruler.after("inline", "task-lists", (state) => {
    const tokens = state.tokens
    for (let i = 2; i < tokens.length; i++) {
      const inline = tokens[i]
      if (inline.type !== "inline" || tokens[i - 1].type !== "paragraph_open" || tokens[i - 2].type !== "list_item_open") continue
      const m = /^\[([ xX])\][ \t]/.exec(inline.content)
      const first = inline.children[0]
      if (!m || !first || first.type !== "text") continue
      first.content = first.content.replace(/^\[[ xX]\][ \t]/, "")
      const box = new state.Token("html_inline", "", 0)
      box.content = `<span class="task-box${m[1] === " " ? "" : " checked"}" role="checkbox" aria-checked="${m[1] !== " "}"></span>`
      inline.children.unshift(box)
      tokens[i - 2].attrJoin("class", "task")
    }
  })
}

const inlineRe = /==(?=\S)(.+?)(?<=\S)==|\[\[([^\[\]|#\n]+)(?:#([^\[\]|\n]+))?(?:\|([^\[\]\n]+))?\]\]/g

function marksAndWikiLinks(md) {
  md.core.ruler.after("text_join", "pero-inline", (state) => {
    for (const block of state.tokens) {
      if (block.type !== "inline" || !block.children) continue
      const out = []
      for (const tok of block.children) {
        if (tok.type !== "text" || !inlineRe.test(tok.content)) { out.push(tok); continue }
        inlineRe.lastIndex = 0
        let last = 0, m
        const text = (s) => { const t = new state.Token("text", "", 0); t.content = s; out.push(t) }
        const html = (s) => { const t = new state.Token("html_inline", "", 0); t.content = s; out.push(t) }
        while ((m = inlineRe.exec(tok.content))) {
          if (m.index > last) text(tok.content.slice(last, m.index))
          if (m[1] != null) { html("<mark>"); text(m[1]); html("</mark>") }
          else {
            const target = m[2].trim()
            const href = encodeURI(target + ".md") + (m[3] ? "#" + encodeURIComponent(m[3].trim()) : "")
            html(`<a class="wiki" href="${escapeHTML(href)}">`)
            text((m[4] || target).trim())
            html("</a>")
          }
          last = m.index + m[0].length
        }
        if (last < tok.content.length) text(tok.content.slice(last))
      }
      block.children = out
    }
  })
}

// With raw HTML off, still let through the tags Перо writes itself.
const allowed = /^<(\/?u|br\s*\/?|\/?mark)>$/i
const imgTag = /^<img\s[^>]*>$/i

function safeImg(tag, resolveImage) {
  const src = (/src\s*=\s*"([^"]*)"/i.exec(tag) || [])[1]
  if (!src) return null
  const width = (/width\s*=\s*"?(\d+)/i.exec(tag) || [])[1]
  const alt = (/alt\s*=\s*"([^"]*)"/i.exec(tag) || [])[1] || ""
  return `<img src="${escapeHTML(resolveImage(src))}"${width ? ` width="${width}"` : ""} alt="${escapeHTML(alt)}">`
}

function notesHtml(md, resolveImage) {
  md.inline.ruler.before("html_inline", "pero-html", (state, silent) => {
    if (state.src.charCodeAt(state.pos) !== 0x3C) return false
    const rest = state.src.slice(state.pos)
    const m = /^<[^<>\n]{0,400}>/.exec(rest)
    if (!m) return false
    let html = null
    if (allowed.test(m[0])) html = m[0].toLowerCase()
    else if (imgTag.test(m[0])) html = safeImg(m[0], resolveImage)
    if (html == null) return false
    if (!silent) state.push("html_inline", "", 0).content = html
    state.pos += m[0].length
    return true
  })
  md.block.ruler.before("html_block", "pero-img-block", (state, startLine, endLine, silent) => {
    const start = state.bMarks[startLine] + state.tShift[startLine]
    const line = state.src.slice(start, state.eMarks[startLine]).trim()
    if (!imgTag.test(line)) return false
    if (silent) return true
    const html = safeImg(line, resolveImage)
    if (!html) return false
    state.push("html_block", "", 0).content = "<p>" + html + "</p>\n"
    state.line = startLine + 1
    return true
  })
}

// html: true lets all raw HTML through (export of the user's own notes, as before).
export function notesMarkdownIt({html = false, highlight, resolveImage = (s) => s} = {}) {
  const md = new MarkdownIt({html, linkify: true, highlight})
  md.use(taskLists)
  md.use(marksAndWikiLinks)
  if (!html) md.use(notesHtml, resolveImage)
  return md
}
