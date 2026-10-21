// Shared state between the editor and the native shell.

export const ctx = {
  baseDir: null, // folder of the open document, for relative image paths
  notes: false, // the library window: Notes typography, title line
  autoSortChecked: false, // move checked items to the bottom of a checklist
  home: null, // the user's home folder, for "~/…" paths
}

const native = window.webkit?.messageHandlers?.pero

export function post(msg) {
  if (native) native.postMessage(msg)
  else console.debug("[pero → native]", msg)
}

const external = /^[a-z][a-z0-9+.-]*:/i

function joinPath(dir, rel) {
  const parts = (rel.startsWith("/") ? rel : dir + "/" + rel).split("/")
  const out = []
  for (const p of parts) {
    if (p === "" || p === ".") continue
    if (p === "..") out.pop()
    else out.push(p)
  }
  return "/" + out.join("/")
}

function decode(s) {
  try { return decodeURIComponent(s) } catch { return s }
}

// Absolute filesystem path for a link or image target, or null for web URLs.
export function localPath(src) {
  src = src.trim().replace(/^<|>$/g, "")
  if (/^file:\/\//i.test(src)) return decode(src.replace(/^file:\/\//i, ""))
  if (external.test(src) || src.startsWith("#")) return null
  src = decode(src.split(/[?#]/)[0])
  if (src.startsWith("/")) return joinPath("", src)
  if (src.startsWith("~/") && ctx.home) return joinPath(ctx.home, src.slice(2))
  if (!ctx.baseDir) return null
  return joinPath(ctx.baseDir, src)
}

// URL the web view can load for an image written in the document.
export function resolveImageURL(src) {
  const path = localPath(src)
  if (path === null) return src.trim().replace(/^<|>$/g, "")
  if (!native) return src // in a plain browser (development) there is no file scheme
  return "pero://file" + path.split("/").map(encodeURIComponent).join("/")
}

export function openLink(href) {
  href = href.trim().replace(/^<|>$/g, "")
  if (/^www\./i.test(href)) href = "https://" + href
  post({type: "openLink", href, path: localPath(href)})
}
