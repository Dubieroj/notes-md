#!/bin/bash
# Automated check of Notes MD. Runs the app in the background (without taking focus) on copies
# of files in a temp folder: types and edits, saves, exports and takes window screenshots.
# The original files are not changed.
#   tools/check.sh                 — the sample from examples/
#   tools/check.sh ~/path/to/*.md  — also checks "open → save → same bytes" on your own files
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
# Separate build with test hooks (the regular build has none); rebuilt only if something changed.
APP="$ROOT/build/test/Notes MD.app"
PERO_TEST_HOOKS=1 NO_OPEN=1 ./run.sh || exit 1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pero-check.XXXXXX")
CMD="$WORK/cmd"; DOCS="$WORK/docs"; SHOTS="$WORK/shots"
mkdir -p "$CMD" "$DOCS/вложенная" "$SHOTS"
cp examples/* "$DOCS/"
printf '# Вложенный файл\n\nТекст.\n' > "$DOCS/вложенная/заметка.md"
EXAMPLE="$DOCS/Пример.md"

FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILED=1; }

# Send a command to the app's test hooks (see Sources/Pero/TestHooks.swift).
pc() {
  local id="c$RANDOM$RANDOM"
  printf '%s' "$1" > "$CMD/$id.tmp" && mv "$CMD/$id.tmp" "$CMD/$id.cmd.json"
  for _ in $(seq 1 150); do
    if [ -f "$CMD/$id.out.json" ]; then
      python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["result"]; print(r if isinstance(r,str) else json.dumps(r,ensure_ascii=False))' "$CMD/$id.out.json"
      rm -f "$CMD/$id.out.json"; return 0
    fi
    sleep 0.1
  done
  echo TIMEOUT; return 1
}
# act ACTION FILE [ARG [key=value ...]] — Python builds the JSON, so no quoting hassle.
act() {
  pc "$(python3 -c '
import json, sys
a = sys.argv[1:]
d = {"action": a[0], "path": a[1]}
if len(a) > 2: d["arg"] = a[2]
for kv in a[3:]:
    k, v = kv.split("=", 1)
    d[k] = json.loads(v)
print(json.dumps(d, ensure_ascii=False))' "$@")"
}
js() { act js "$1" "$2"; }
window_of() { pc '{"action":"windows"}' | python3 -c 'import json,sys,os; r=os.path.realpath; print(next(d["window"] for d in json.load(sys.stdin) if r(d["path"])==r(sys.argv[1])))' "$1"; }
shot() { screencapture -x -o -l "$(window_of "$1")" "$SHOTS/$2.png"; }

echo "Test folder: $WORK"
# Separate empty library: the check doesn't touch real notes.
# Settings of earlier test runs (linked folders, library folder) must not leak in.
defaults delete local.pero.markdown.tests 2>/dev/null || true
open -g -n --env PERO_TEST_DIR="$CMD" --env PERO_LIBRARY="$WORK/library" -a "$APP" "$EXAMPLE"
for _ in $(seq 1 50); do [ "$(js "$EXAMPLE" 'return pero.getText().length')" != TIMEOUT ] && break; sleep 0.2; done

echo "Open and save without edits"
roundtrip() {
  local file=$1 before
  before=$(md5 -q "$file")
  js "$file" "window.webkit.messageHandlers.pero.postMessage({type: 'edit', changes: [], length: pero.getText().length})" >/dev/null
  sleep 0.3
  local result
  result=$(act save "$file")
  [ "$result" = true ] || fail "$(basename "$file"): not saved"
  [ "$(md5 -q "$file")" = "$before" ] && pass "$(basename "$file"): bytes match" || fail "$(basename "$file"): file changed"
}
roundtrip "$EXAMPLE"
for src in "$@"; do
  copy="$DOCS/$(basename "$src")"
  cp "$src" "$copy"
  act openFromSidebar "$EXAMPLE" "$copy" >/dev/null
  for _ in $(seq 1 30); do [ "$(js "$copy" 'return 1')" = 1 ] && break; sleep 0.2; done
  sleep 0.5
  roundtrip "$copy"
  shot "$copy" "file-$(basename "$copy" .md)"
done

echo "Any Markdown file from Finder"
# .mkd, .mdwn… are declared by other apps (Typora) as their own types; the app opens them too.
mkdir -p "$DOCS/finder"
for ext in mkd mdwn mdtxt mdtext MARKDOWN; do
  f="$DOCS/finder/Файл.$ext"
  printf '# Файл .%s\n\nОткрыт из Finder.\n' "$ext" > "$f"
  open -g -a "$APP" "$f"
  shown=0
  for _ in $(seq 1 30); do shown=$(js "$f" 'return pero.getText().includes("Открыт из Finder") ? 1 : 0'); [ "$shown" = 1 ] && break; sleep 0.2; done
  [ "$shown" = 1 ] && pass ".$ext opens" || fail ".$ext did not open"
  act close "$f" >/dev/null  # extra windows get in the way of typing in the sample later
done
f="$DOCS/finder/Только чтение.md"
printf '# Только чтение\n\nОткрыт из Finder.\n' > "$f"; chmod 444 "$f"
open -g -a "$APP" "$f"
shown=0
for _ in $(seq 1 30); do shown=$(js "$f" 'return pero.getText().includes("Открыт из Finder") ? 1 : 0'); [ "$shown" = 1 ] && break; sleep 0.2; done
[ "$shown" = 1 ] && pass "read-only file opens" || fail "read-only file did not open"
act close "$f" >/dev/null; chmod 644 "$f"

echo "Screenshots"
shot "$EXAMPLE" 1-live-dark
act appearance "" light >/dev/null; sleep 0.5
shot "$EXAMPLE" 2-live-light
js "$EXAMPLE" 'const v = pero.view; v.scrollDOM.scrollTop = v.lineBlockAt(v.state.doc.toString().indexOf("## Таблица")).top - 40; await new Promise(r => setTimeout(r, 400)); return 1' >/dev/null
shot "$EXAMPLE" 3-table-code
act action "$EXAMPLE" toggleSourceMode: >/dev/null; sleep 0.4
shot "$EXAMPLE" 4-source
act action "$EXAMPLE" toggleSourceMode: >/dev/null
act tab "$EXAMPLE" outline >/dev/null; sleep 0.4
shot "$EXAMPLE" 5-outline
act appearance "" system >/dev/null

echo "Editing"
# Cursor to the end of the last line, then type via window key events.
js "$EXAMPLE" 'const t = pero.getText(); pero.reveal(t.indexOf("Последняя строка.") + 17); return 1' >/dev/null
for ch in " " "и" " " "е" "щ" "ё"; do act key "$EXAMPLE" "$ch" keyCode=0 >/dev/null; done
js "$EXAMPLE" 'const t = pero.getText(); const i = t.lastIndexOf("ещё"); pero.view.dispatch({selection: {anchor: i, head: i + 3}}); return 1' >/dev/null
act key "$EXAMPLE" b keyCode=11 'modifiers=["cmd"]' >/dev/null; sleep 0.3
# Checkbox: a real mousedown on the drawn box.
js "$EXAMPLE" 'const v = pero.view; v.contentDOM.blur(); v.scrollDOM.scrollTop = v.lineBlockAt(v.state.doc.toString().indexOf("- [ ] Нажать")).top - 100; await new Promise(r => setTimeout(r, 400)); const boxes = document.querySelectorAll(".cm-task-box"); boxes[boxes.length - 1].dispatchEvent(new MouseEvent("mousedown", {bubbles: true, cancelable: true})); return 1' >/dev/null
T0=$(date +%s)
saved=""
for i in $(seq 1 15); do sleep 1; [ "$(stat -f %m "$EXAMPLE")" -ge "$T0" ] && { saved=$i; break; }; done
[ -n "$saved" ] && pass "autosaved after ${saved} s" || fail "no autosave within 15 s"
grep -q '^Последняя строка\. и \*\*ещё\*\*$' "$EXAMPLE" && pass "typed text and ⌘B are in the file" || fail "typed text is not in the file"
grep -q '^- \[x\] Нажать на квадратик' "$EXAMPLE" && pass "checkbox checked in the file" || fail "checkbox not saved"
changed=$(diff "$ROOT/examples/Пример.md" "$EXAMPLE" | grep -c '^[<>]')
[ "$changed" = 4 ] && pass "rest of the text untouched (2 lines changed)" || fail "lines changed: $((changed / 2)), expected 2"

echo "Export"
html=$(act exportHTML "$EXAMPLE" "$WORK/Пример.html")
[ "$html" = ok ] \
  && grep -q '<table>' "$WORK/Пример.html" && grep -q 'tok-keyword' "$WORK/Пример.html" \
  && pass "HTML: $WORK/Пример.html" || fail "HTML export"
pdf=$(act exportPDF "$EXAMPLE" "$WORK/Пример.pdf")
[ "$pdf" = ok ] \
  && head -c 5 "$WORK/Пример.pdf" | grep -q '%PDF' \
  && pass "PDF: $WORK/Пример.pdf" || fail "PDF export"

echo "Quit right after an edit"
js "$EXAMPLE" 'pero.view.dispatch({changes: {from: pero.view.state.doc.length, insert: "Перед выходом.\n"}, userEvent: "input.type"}); return 1' >/dev/null
pc '{"action":"quit"}' >/dev/null
# The test copy must not stay in "Open With" next to the app from Applications.
sleep 1; LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister; "$LSR" -u "$APP" 2>/dev/null
for _ in $(seq 1 50); do sleep 0.2; [ "$(tail -n 1 "$EXAMPLE")" = "Перед выходом." ] && break; done
[ "$(tail -n 1 "$EXAMPLE")" = "Перед выходом." ] && pass "edit saved on quit" || fail "edit made before quit was lost"

echo "Window screenshots: $SHOTS"
[ $FAILED = 0 ] && echo "All good." || { echo "There were failures."; exit 1; }
