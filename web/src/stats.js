// Word and character counts for the status line.
import {getLang, t} from "./i18n.js"

function plural(n, one, few, many) {
  const m10 = n % 10, m100 = n % 100
  if (m10 === 1 && m100 !== 11) return one
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few
  return many
}

// English has one form for 1 and another for the rest.
const ru = () => getLang() === "ru"
const wordsWord = (n) => (ru() ? plural(n, "слово", "слова", "слов") : n === 1 ? "word" : "words")
const charsWord = (n) => (ru() ? plural(n, "символ", "символа", "символов") : n === 1 ? "character" : "characters")

const wordRe = /[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*/gu

export function countWords(text) {
  const prose = text
    .replace(/^([ \t>]*)(?:[-*+]|\d+[.)])[ \t]+\[[ xX]\]/gm, "$1") // task markers are not words
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1") // keep link text, drop the URL
    .replace(/<[^>\n]+>/g, " ")
  return (prose.match(wordRe) || []).length
}

export function countChars(text) {
  return text.replace(/\n/g, "").length
}

const fmt = (n) => n.toLocaleString(ru() ? "ru-RU" : "en-US")

export function statsLabel(state) {
  const sel = state.selection.ranges.reduce((s, r) => (r.empty ? s : s + state.sliceDoc(r.from, r.to) + "\n"), "")
  const text = state.doc.toString()
  const words = countWords(text)
  if (sel) {
    const w = countWords(sel)
    return ru()
      ? `Выделено ${fmt(w)} ${wordsWord(w)} из ${fmt(words)}`
      : `${fmt(w)} of ${fmt(words)} ${wordsWord(words)} selected`
  }
  const chars = countChars(text)
  // Reading time at about 200 words a minute.
  const minutes = Math.max(1, Math.ceil(words / 200))
  return `${fmt(words)} ${wordsWord(words)} · ${fmt(chars)} ${charsWord(chars)} · ${minutes} ${t("мин чтения")}`
}
