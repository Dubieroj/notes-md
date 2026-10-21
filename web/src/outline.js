// Headings of the document for the sidebar outline.
import {ensureSyntaxTree, syntaxTree} from "@codemirror/language"
import {t} from "./i18n.js"

function plain(text) {
  return text
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[*_`~]+/g, "")
    .replace(/\\(.)/g, "$1")
    .trim()
}

export function headings(state) {
  const tree = ensureSyntaxTree(state, state.doc.length, 300) || syntaxTree(state)
  const items = []
  tree.iterate({
    enter(node) {
      const m = /^(ATX|Setext)Heading(\d)$/.exec(node.name)
      if (m) {
        let text = state.sliceDoc(node.from, node.to)
        text = m[1] === "ATX"
          ? text.replace(/^#{1,6}[ \t]*/, "").replace(/[ \t]+#+[ \t]*$/, "")
          : text.split("\n").slice(0, -1).join(" ")
        items.push({level: Number(m[2]), text: plain(text) || t("Без названия"), from: node.from})
        return false
      }
      return node.name === "Document"
    },
  })
  return items
}

// Index of the heading the reader is in, judged by the top of the viewport.
export function currentHeading(items, pos) {
  let index = -1
  for (let i = 0; i < items.length && items[i].from <= pos; i++) index = i
  return index
}
