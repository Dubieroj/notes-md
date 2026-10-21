// Bundles the editor page into ../Resources/web (loaded by the app via pero://app/).
import * as esbuild from "esbuild"
import {cpSync, rmSync, mkdirSync, readFileSync, writeFileSync, existsSync} from "node:fs"

const out = new URL("../Resources/web/", import.meta.url).pathname
rmSync(out, {recursive: true, force: true})
mkdirSync(out, {recursive: true})

await esbuild.build({
  entryPoints: ["src/main.js"],
  bundle: true,
  format: "esm",
  splitting: true, // code languages load on demand
  minify: true,
  target: "safari16",
  outdir: out + "js",
  chunkNames: "chunks/[name]-[hash]",
  loader: {".css": "text"},
  legalComments: "none",
  logLevel: "warning",
})

// Quick Look renders with the same markdown-it setup, as one script for JavaScriptCore.
await esbuild.build({
  entryPoints: ["src/render.js"],
  bundle: true,
  format: "iife",
  globalName: "PeroRender",
  minify: true,
  target: "safari16",
  outfile: new URL("../Resources/render/render.js", import.meta.url).pathname,
  loader: {".css": "text"},
  legalComments: "none",
  logLevel: "warning",
})

cpSync("public", out, {recursive: true})
cpSync("src/tokens.css", out + "tokens.css")

// Licenses of everything bundled into the app.
const pkg = JSON.parse(readFileSync("package.json", "utf8"))
const seen = new Set(), notices = []
const visit = (name) => {
  if (seen.has(name)) return
  seen.add(name)
  const dir = `node_modules/${name}/`
  if (!existsSync(dir + "package.json")) return
  const meta = JSON.parse(readFileSync(dir + "package.json", "utf8"))
  const file = ["LICENSE", "LICENSE.md", "LICENSE.txt", "license"].map((f) => dir + f).find(existsSync)
  notices.push(`${name} ${meta.version} (${meta.license})\n\n${file ? readFileSync(file, "utf8").trim() : ""}`)
  Object.keys(meta.dependencies || {}).forEach(visit)
}
Object.keys(pkg.dependencies).forEach(visit)
writeFileSync(out + "third-party-licenses.txt", notices.sort().join("\n\n" + "-".repeat(72) + "\n\n") + "\n")
