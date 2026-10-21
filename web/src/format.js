// Formatting commands for the keyboard shortcuts and the Format menu.
import {EditorSelection} from "@codemirror/state"

// Wrap the selection in a marker, or unwrap it if it is already wrapped.
export function toggleWrap(marker) {
  return (view) => {
    const {state} = view
    const n = marker.length
    const tr = state.changeByRange((range) => {
      const before = state.sliceDoc(range.from - n, range.from)
      const after = state.sliceDoc(range.to, range.to + n)
      if (before === marker && after === marker) {
        return {
          changes: [{from: range.from - n, to: range.from}, {from: range.to, to: range.to + n}],
          range: EditorSelection.range(range.from - n, range.to - n),
        }
      }
      const text = state.sliceDoc(range.from, range.to)
      if (text.length > 2 * n && text.startsWith(marker) && text.endsWith(marker)) {
        return {
          changes: {from: range.from, to: range.to, insert: text.slice(n, -n)},
          range: EditorSelection.range(range.from, range.to - 2 * n),
        }
      }
      return {
        changes: [{from: range.from, insert: marker}, {from: range.to, insert: marker}],
        range: EditorSelection.range(range.from + n, range.to + n),
      }
    })
    view.dispatch(state.update(tr, {scrollIntoView: true, userEvent: "input.format"}))
    return true
  }
}

export function insertLink(view) {
  const {state} = view
  const tr = state.changeByRange((range) => {
    const text = state.sliceDoc(range.from, range.to)
    if (/^(https?:\/\/|www\.)\S+$/.test(text)) {
      return {
        changes: {from: range.from, to: range.to, insert: `[](${text})`},
        range: EditorSelection.cursor(range.from + 1),
      }
    }
    const insert = `[${text}]()`
    const cursor = text ? range.from + insert.length - 1 : range.from + 1
    return {changes: {from: range.from, to: range.to, insert}, range: EditorSelection.cursor(cursor)}
  })
  view.dispatch(state.update(tr, {scrollIntoView: true, userEvent: "input.format"}))
  return true
}

// ⌘0…⌘6 (headings) live in notesKeymap, with the paragraph styles.
export const formatKeymap = [
  {key: "Mod-b", run: toggleWrap("**")},
  {key: "Mod-i", run: toggleWrap("*")},
  {key: "Mod-e", run: toggleWrap("`")},
  {key: "Mod-Shift-x", run: toggleWrap("~~")},
  {key: "Mod-k", run: insertLink},
]
