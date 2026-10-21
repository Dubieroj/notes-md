// Suggestions while typing: note titles after [[ or >> (Notes's note links), tags after #,
// languages after ```. Titles and tags come from the shell through ctx.
import {autocompletion, completionKeymap} from "@codemirror/autocomplete"
import {keymap} from "@codemirror/view"
import {syntaxTree} from "@codemirror/language"
import {languages} from "@codemirror/language-data"
import {ctx} from "./ctx.js"

const languageNames = [...new Set(languages.flatMap((l) => [l.name.toLowerCase(), ...l.alias]))].sort()

function inCode(state, pos) {
  for (let n = syntaxTree(state).resolveInner(pos, -1); n; n = n.parent)
    if (n.name === "InlineCode" || n.name === "FencedCode" || n.name === "CodeBlock") return true
  return false
}

function source(context) {
  const line = context.state.doc.lineAt(context.pos)
  const before = line.text.slice(0, context.pos - line.from)

  // [[Тит… or >>Тит… → [[Title]]; ">> " is a nested quote, and code is left alone.
  let m = /(\[\[|>>(?!\s))([^\[\]|#\n]*)$/.exec(before)
  if (m && (ctx.titles || []).length && !inCode(context.state, context.pos)) {
    const start = context.pos - m[0].length
    const after = context.state.sliceDoc(context.pos, context.pos + 2)
    return {
      from: context.pos - m[2].length,
      options: ctx.titles.map((title) => ({
        label: title,
        type: "text",
        apply(view, completion, from, to) {
          const insert = "[[" + title + "]]"
          const end = m[1] === "[[" && after === "]]" ? to + 2 : to
          view.dispatch({changes: {from: start, to: end, insert}, selection: {anchor: start + insert.length}, userEvent: "input.complete"})
        },
      })),
      validFor: m[1] === ">>" ? /^(?!\s)[^\[\]|#\n]*$/ : /^[^\[\]|#\n]*$/,
    }
  }

  // #та… → #тег (not a heading: those need a space after #)
  m = /(^|[\s(\[{,;:!?«"'])#([\p{L}\p{N}_\-]*)$/u.exec(before)
  if (m && (ctx.tags || []).length && !(m[1] === "" && /^#+$/.test(before))) {
    return {
      from: context.pos - m[2].length,
      options: ctx.tags.map((tag) => ({label: tag, type: "keyword"})),
      validFor: /^[\p{L}\p{N}_\-]*$/u,
    }
  }

  // ```py → language of a code block
  m = /^\s*(```|~~~)([\w+#-]*)$/.exec(before)
  if (m && context.explicit !== false) {
    return {from: context.pos - m[2].length, options: languageNames.map((label) => ({label, type: "type"})), validFor: /^[\w+#-]*$/}
  }
  return null
}

export const completion = [
  autocompletion({override: [source], icons: false, closeOnBlur: true, activateOnTypingDelay: 50}),
  keymap.of(completionKeymap),
]
