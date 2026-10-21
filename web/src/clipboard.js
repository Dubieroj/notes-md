// Copy puts Markdown and HTML on the clipboard; paste turns rich text into Markdown
// and files (pictures, PDFs) into attachments saved by the shell.
import {EditorView} from "@codemirror/view"
import {htmlToMarkdown} from "./htmlmd.js"
import {exportFragment} from "./export.js"
import {post} from "./ctx.js"

const ownType = "application/x-pero-markdown"

function selectedText(view) {
  return view.state.selection.ranges.filter((r) => !r.empty).map((r) => view.state.sliceDoc(r.from, r.to)).join("\n")
}

// Pictures in pasted HTML get placeholder ids not used before by this page or the note,
// so one that fails to save is never filled with a later paste's file.
let nextImage = 0

function firstImageId(view) {
  let id = nextImage
  for (const m of view.state.doc.toString().matchAll(/\(pero-pending:(\d{1,4})\)/g)) id = Math.max(id, Number(m[1]) + 1)
  return id
}

function readFile(file) {
  return new Promise((resolve) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result).replace(/^data:[^,]*,/, ""))
    reader.onerror = () => resolve(null)
    reader.readAsDataURL(file)
  })
}

// Files go to the shell, which saves them and inserts the Markdown for them.
export async function sendFiles(files, pos) {
  for (const file of files) {
    const data = await readFile(file)
    if (data) post({type: "attachFile", name: file.name || "Вставка", mime: file.type, data, pos})
  }
}

export const pasteAndCopy = EditorView.domEventHandlers({
  copy(e, view) { return writeClipboard(e, view, false) },
  cut(e, view) { return writeClipboard(e, view, true) },
  paste(e, view) {
    const data = e.clipboardData
    if (!data || view.state.readOnly) return false
    const files = [...data.files]
    if (files.length && !data.types.includes("text/plain")) {
      e.preventDefault()
      sendFiles(files, view.state.selection.main.from)
      return true
    }
    if (data.types.includes(ownType)) {
      e.preventDefault()
      view.dispatch(view.state.replaceSelection(data.getData(ownType)), {userEvent: "input.paste", scrollIntoView: true})
      return true
    }
    if (data.types.includes("text/html")) {
      const first = firstImageId(view)
      const {markdown, images} = htmlToMarkdown(data.getData("text/html"), first)
      if (!markdown && files.length) { e.preventDefault(); sendFiles(files, view.state.selection.main.from); return true }
      if (!markdown) return false
      e.preventDefault()
      // A single plain line pastes as plain text; anything richer as Markdown.
      const plain = data.getData("text/plain")
      const text = markdown.replace(/\\([\\`*_\[\]])/g, "$1") === plain.trim() ? plain : markdown
      view.dispatch(view.state.replaceSelection(text), {userEvent: "input.paste", scrollIntoView: true})
      if (images.length) {
        // The shell looks for images[i] as "(pero-pending:i)": earlier ids are left empty.
        nextImage = first + images.length
        post({type: "pendingImages", images: [...Array(first).fill(""), ...images]})
      }
      return true
    }
    if (files.length) {
      e.preventDefault()
      sendFiles(files, view.state.selection.main.from)
      return true
    }
    return false
  },
  drop(e, view) {
    const files = [...(e.dataTransfer?.files || [])]
    if (!files.length || view.state.readOnly) return false
    e.preventDefault()
    const pos = view.posAtCoords({x: e.clientX, y: e.clientY}) ?? view.state.selection.main.head
    view.dispatch({selection: {anchor: pos}})
    sendFiles(files, pos)
    return true
  },
})

function writeClipboard(e, view, cut) {
  const text = selectedText(view)
  if (!text || !e.clipboardData) return false
  e.preventDefault()
  e.clipboardData.setData("text/plain", text)
  e.clipboardData.setData(ownType, text)
  try { e.clipboardData.setData("text/html", exportFragment(text)) } catch {}
  if (cut && !view.state.readOnly) view.dispatch(view.state.replaceSelection(""), {userEvent: "delete.cut"})
  return true
}
