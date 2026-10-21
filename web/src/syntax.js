// Markdown additions for Notes features: ==highlight==, [[wiki links]] and #tags.
import {Tag, tags as t} from "@lezer/highlight"

export const highlightTag = Tag.define()
export const hashtagTag = Tag.define()

let Punctuation = /[!"#$%&'()*+,\-.\/:;<=>?@\[\\\]^_`{|}~\xA1‐-‧]/
try { Punctuation = new RegExp("[\\p{S}|\\p{P}]", "u") } catch {}

const HighlightDelim = {resolve: "Highlight", mark: "HighlightMark"}

const Highlight = {
  defineNodes: [
    {name: "Highlight", style: {"Highlight/...": highlightTag}},
    {name: "HighlightMark", style: t.processingInstruction},
  ],
  parseInline: [{
    name: "Highlight",
    parse(cx, next, pos) {
      if (next != 61 /* = */ || cx.char(pos + 1) != 61 || cx.char(pos + 2) == 61) return -1
      const before = pos > cx.offset ? cx.slice(pos - 1, pos) : "", after = cx.slice(pos + 2, pos + 3)
      const sBefore = /\s|^$/.test(before), sAfter = /\s|^$/.test(after)
      const pBefore = Punctuation.test(before), pAfter = Punctuation.test(after)
      return cx.addDelimiter(HighlightDelim, pos, pos + 2, !sAfter && (!pAfter || sBefore || pBefore), !sBefore && (!pBefore || sAfter || pAfter))
    },
    after: "Emphasis",
  }],
}

const WikiLink = {
  defineNodes: [
    {name: "WikiLink", style: {"WikiLink/...": t.link}},
    {name: "WikiMark", style: t.processingInstruction},
  ],
  parseInline: [{
    name: "WikiLink",
    parse(cx, next, pos) {
      if (next != 91 /* [ */ || cx.char(pos + 1) != 91) return -1
      for (let i = pos + 2; i < cx.end - 1; i++) {
        const c = cx.char(i)
        if (c == 10 || c == 91) return -1
        if (c == 93 /* ] */) {
          if (cx.char(i + 1) != 93 || i == pos + 2) return -1
          return cx.addElement(cx.elt("WikiLink", pos, i + 2, [cx.elt("WikiMark", pos, pos + 2), cx.elt("WikiMark", i, i + 2)]))
        }
      }
      return -1
    },
    before: "Link",
  }],
}

const tagChar = /[\p{L}\p{N}_\-]/u
const letter = /\p{L}/u
const tagBoundary = /[\s(\[{,;:!?«"'“„]/

const Hashtag = {
  defineNodes: [{name: "Hashtag", style: hashtagTag}],
  parseInline: [{
    name: "Hashtag",
    parse(cx, next, pos) {
      if (next != 35 /* # */) return -1
      if (pos > cx.offset && !tagBoundary.test(cx.slice(pos - 1, pos))) return -1
      let i = pos + 1, hasLetter = false
      while (i < cx.end) {
        const ch = cx.slice(i, i + 1)
        if (!tagChar.test(ch)) break
        if (letter.test(ch)) hasLetter = true
        i++
      }
      while (i > pos + 1 && /[-_]/.test(cx.slice(i - 1, i))) i--
      if (!hasLetter) return -1
      return cx.addElement(cx.elt("Hashtag", pos, i))
    },
    before: "Emphasis",
  }],
}

export const notesSyntax = [Highlight, WikiLink, Hashtag]
