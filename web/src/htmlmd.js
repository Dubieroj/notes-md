// HTML → Markdown for pasted rich text and imported notes (Apple Notes, web pages,
// Pages, Google Docs). Formatting Markdown cannot hold (fonts, colours) is dropped.

const blockTags = new Set(["P", "DIV", "SECTION", "ARTICLE", "HEADER", "FOOTER", "MAIN", "ASIDE", "NAV", "FIGURE",
  "H1", "H2", "H3", "H4", "H5", "H6", "UL", "OL", "LI", "BLOCKQUOTE", "PRE", "TABLE", "HR", "DL", "DT", "DD", "TR"])

function escapeText(s) {
  return s.replace(/([\\`*_\[\]])/g, "\\$1").replace(/(^|\s)(=)(?==)/g, "$1\\$2")
}

function escapeLineStart(line) {
  return line
    .replace(/^(\s*)([#>])/, "$1\\$2")
    .replace(/^(\s*)([-+])(\s)/, "$1\\$2$3")
    .replace(/^(\s*\d+)([.)])(\s)/, "$1\\$2$3")
}

function styleOf(el) {
  const s = (el.getAttribute && el.getAttribute("style")) || ""
  return {
    bold: /font-weight\s*:\s*(bold|[6-9]00)/i.test(s),
    italic: /font-style\s*:\s*italic/i.test(s),
    strike: /text-decoration[^;]*line-through/i.test(s),
    underline: /text-decoration[^;]*underline/i.test(s),
    mono: /font-family[^;]*(mono|courier|menlo|consolas)/i.test(s),
  }
}

function wrap(text, open, close = open) {
  if (!text.trim()) return text
  const lead = /^\s*/.exec(text)[0], trail = /\s*$/.exec(text)[0]
  return lead + open + text.trim() + close + trail
}

// Inline content of an element as one Markdown string.
function inline(node, ctx) {
  let out = ""
  for (const child of node.childNodes) out += inlineNode(child, ctx)
  return out
}

function inlineNode(node, ctx) {
  if (node.nodeType === 3) {
    const text = ctx.pre ? node.nodeValue : node.nodeValue.replace(/[ \t\r\n]+/g, " ")
    return ctx.pre || ctx.code ? text : escapeText(text)
  }
  if (node.nodeType !== 1) return ""
  const el = node
  const tag = el.tagName
  if (blockTags.has(tag)) return "\n" + block(el, ctx).trim() + "\n"
  switch (tag) {
    case "BR": return ctx.cell ? "<br>" : "\\\n"
    case "B": case "STRONG": {
      // Google Docs wraps everything in <b style="font-weight:normal">.
      const inner = inline(el, ctx)
      return /font-weight\s*:\s*(normal|400)/i.test(el.getAttribute("style") || "") ? inner : wrap(inner, "**")
    }
    case "I": case "EM": case "CITE": return wrap(inline(el, ctx), "*")
    case "S": case "DEL": case "STRIKE": return wrap(inline(el, ctx), "~~")
    case "U": case "INS": return wrap(inline(el, ctx), "<u>", "</u>")
    case "MARK": return wrap(inline(el, ctx), "==")
    case "CODE": case "KBD": case "SAMP": case "TT": {
      const text = inline(el, {...ctx, code: true})
      const ticks = text.includes("`") ? "``" : "`"
      return text ? ticks + text + ticks : ""
    }
    case "A": {
      const href = el.getAttribute("href") || ""
      const text = inline(el, ctx).trim()
      if (!href || href.startsWith("javascript:")) return text
      if (text === href || text === href.replace(/^mailto:/, "")) return /^https?:/.test(href) ? href : `<${href}>`
      return `[${text || href}](${/[\s()]/.test(href) ? `<${href}>` : href})`
    }
    case "IMG": {
      const src = el.getAttribute("src") || ""
      if (!src) return ""
      const alt = (el.getAttribute("alt") || "").replace(/[\[\]]/g, "").replace(/\s+/g, " ")
      if (src.startsWith("data:")) { ctx.images.push(src); return `![${alt}](pero-pending:${ctx.firstImage + ctx.images.length - 1})` }
      return `![${alt}](${/[\s()]/.test(src) ? `<${src}>` : src})`
    }
    case "INPUT":
      if ((el.getAttribute("type") || "").toLowerCase() === "checkbox") return el.hasAttribute("checked") ? "[x] " : "[ ] "
      return ""
    case "SCRIPT": case "STYLE": case "HEAD": case "META": case "TITLE": case "OBJECT": return ""
    case "SPAN": case "FONT": default: {
      let text = inline(el, ctx)
      const st = styleOf(el)
      if (st.mono && !ctx.code) text = text.trim() ? "`" + text.replace(/\\([\\`*_\[\]])/g, "$1") + "`" : text
      if (st.bold) text = wrap(text, "**")
      if (st.italic) text = wrap(text, "*")
      if (st.strike) text = wrap(text, "~~")
      if (st.underline) text = wrap(text, "<u>", "</u>")
      return text
    }
  }
}

function lines(text) {
  return text.split("\n").map((l) => l.replace(/[ \t]+$/, "")).join("\n").replace(/\n{3,}/g, "\n\n")
}

function paragraph(text) {
  return lines(text).split("\n").map(escapeLineStart).join("\n").trim()
}

function listBlock(el, ctx) {
  const ordered = el.tagName === "OL"
  const dash = /dash/i.test(el.getAttribute("class") || "")
  let n = parseInt(el.getAttribute("start") || "1", 10) || 1
  const items = []
  for (const li of el.children) {
    if (li.tagName !== "LI") continue
    const box = li.querySelector(":scope > input[type=checkbox]")
    const checklist = /checklist|todo|task/i.test(li.getAttribute("class") || "") || box
    const checked = box ? box.hasAttribute("checked") : /checked|done/i.test(li.getAttribute("class") || "")
    const marker = ordered ? `${n++}.` : dash ? "+" : "-"
    let content = ""
    for (const child of li.childNodes) {
      if (child.nodeType === 1 && (child.tagName === "UL" || child.tagName === "OL")) content += "\n" + listBlock(child, ctx) + "\n"
      else if (!(child.nodeType === 1 && child.tagName === "INPUT")) content += inlineNode(child, ctx)
    }
    const pad = " ".repeat(marker.length + 1)
    const body = lines(content).trim().split("\n").map((l, i) => (i === 0 ? l : l ? pad + l : l)).join("\n")
    items.push(marker + " " + (checklist ? (checked ? "[x] " : "[ ] ") : "") + body)
  }
  return items.join("\n")
}

function tableBlock(el, ctx) {
  const rows = [...el.querySelectorAll("tr")].map((tr) =>
    [...tr.children].filter((c) => c.tagName === "TD" || c.tagName === "TH")
      .map((c) => inline(c, {...ctx, cell: true}).replace(/\n+/g, "<br>").replace(/\|/g, "\\|").trim()))
  if (!rows.length) return ""
  const cols = Math.max(...rows.map((r) => r.length))
  const pad = (r) => [...r, ...Array(cols - r.length).fill("")]
  const out = ["| " + pad(rows[0]).join(" | ") + " |", "|" + " --- |".repeat(cols)]
  for (const r of rows.slice(1)) out.push("| " + pad(r).join(" | ") + " |")
  return out.join("\n")
}

function block(el, ctx) {
  const tag = el.tagName
  switch (tag) {
    case "H1": case "H2": case "H3": case "H4": case "H5": case "H6":
      return "#".repeat(Number(tag[1])) + " " + inline(el, ctx).replace(/\s*\n\s*/g, " ").trim()
    case "UL": case "OL": return listBlock(el, ctx)
    case "BLOCKQUOTE": return children(el, ctx).trim().split("\n").map((l) => (l ? "> " + l : ">")).join("\n")
    case "PRE": {
      const code = el.textContent.replace(/\n$/, "")
      const lang = (/language-([\w+-]+)/.exec((el.querySelector("code") || el).getAttribute("class") || "") || [])[1] || ""
      const fence = "`".repeat(Math.max(3, ...(code.match(/`+/g) || []).map((t) => t.length + 1)))
      return fence + lang + "\n" + code + "\n" + fence
    }
    case "TABLE": return tableBlock(el, ctx)
    case "HR": return "---"
    case "LI": return "- " + inline(el, ctx).trim()
    default: {
      // A <div> per line (Apple Notes, contenteditable) or a container of blocks.
      const hasBlocks = [...el.children].some((c) => blockTags.has(c.tagName))
      return hasBlocks ? children(el, ctx) : paragraph(inline(el, ctx))
    }
  }
}

function children(el, ctx) {
  const parts = []
  let run = ""
  const flush = () => { if (run.trim()) parts.push(paragraph(run)); run = "" }
  for (const child of el.childNodes) {
    if (child.nodeType === 1 && blockTags.has(child.tagName)) {
      flush()
      const md = block(child, ctx)
      if (md.trim()) parts.push(md)
      else if (child.tagName === "DIV" || child.tagName === "P") parts.push("") // an empty line kept as a gap
    } else {
      run += inlineNode(child, ctx)
    }
  }
  flush()
  // Apple Notes puts each line in its own <div>: join them as lines, gaps as blank lines.
  const lineDivs = [...el.children].every((c) => c.tagName === "DIV")
  return lineDivs ? parts.join("\n").replace(/\n{3,}/g, "\n\n") : parts.filter((p) => p !== "").join("\n\n")
}

// Returns {markdown, images}: data-URI images come back separately (the shell saves
// them as attachments and replaces pero-pending:N, N = firstImage + index).
export function htmlToMarkdown(html, firstImage = 0) {
  const doc = new DOMParser().parseFromString(html, "text/html")
  const ctx = {images: [], firstImage, pre: false, code: false, cell: false}
  const md = children(doc.body, ctx)
  return {markdown: md.replace(/\n{3,}/g, "\n\n").trim(), images: ctx.images}
}
