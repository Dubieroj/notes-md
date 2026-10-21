#!/bin/bash
# Автопроверка библиотеки заметок. Запускает отдельный экземпляр build/Notes MD.app на
# временной библиотеке (настоящие заметки и установленное приложение не трогаются),
# проходит сценарии как пользователь и сверяет файлы на диске.
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
# Своя сборка с тестовым пультом (в обычной его нет); пересобирается, только если что-то поменялось.
APP="$ROOT/build/test/Notes MD.app"
PERO_TEST_HOOKS=1 NO_OPEN=1 ./run.sh || exit 1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pero-library.XXXXXX")
CMD="$WORK/cmd"; LIB="$WORK/lib"; SHOTS="$WORK/shots"; OUT="$WORK/out"
mkdir -p "$CMD" "$LIB/Работа" "$LIB/Attachments/2026/10" "$SHOTS" "$OUT"
cp examples/icon.png "$LIB/Attachments/2026/10/ab12cd-icon.png"
printf '# Список покупок\n\n- [ ] Молоко\n- [x] Хлеб #дом\n' > "$LIB/Список покупок.md"
printf '# План\n\nТекст\n\n![Значок](../Attachments/2026/10/ab12cd-icon.png)\n' > "$LIB/Работа/План.md"

FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILED=1; }

# Команда тестовому пульту приложения (см. Sources/Pero/TestHooks.swift).
pc() {
  local id="c$RANDOM$RANDOM"
  printf '%s' "$1" > "${CMD:?}/$id.tmp" && mv "${CMD:?}/$id.tmp" "${CMD:?}/$id.cmd.json"
  for _ in $(seq 1 150); do
    if [ -f "${CMD:?}/$id.out.json" ]; then
      python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["result"]; print(r if isinstance(r,str) else json.dumps(r,ensure_ascii=False))' "${CMD:?}/$id.out.json"
      rm -f "${CMD:?}/${id:?}.out.json"; return 0
    fi
    sleep 0.1
  done
  echo TIMEOUT; return 1
}
# j ДЕЙСТВИЕ [АРГУМЕНТ [ключ=JSON ...]] — JSON собирает Python, без возни с кавычками.
j() {
  pc "$(python3 -c '
import json, sys
a = sys.argv[1:]
d = {"action": a[0]}
if len(a) > 1: d["arg"] = a[1]
for kv in a[2:]:
    k, v = kv.split("=", 1)
    d[k] = json.loads(v)
print(json.dumps(d, ensure_ascii=False))' "$@")"
}
# Имена файлов macOS отдаёт в разложенной форме Unicode («й» = «и» + знак): сравниваем в составной.
state() { j main | python3 -c "import json,sys,unicodedata; d=json.load(sys.stdin); print(unicodedata.normalize('NFC', json.dumps(d$1, ensure_ascii=False)))"; }
js() { j mainjs "$1"; }
menu() { if [ $# -gt 1 ]; then j mainaction "$1" "represented=\"$2\""; else j mainaction "$1"; fi; }
shot() { screencapture -x -o -l "$(state '["window"]')" "$SHOTS/$1.png"; }
waitfor() { for _ in $(seq 1 "${2:-40}"); do eval "$1" && return 0; sleep 0.25; done; return 1; }
line() { sed -n "$2p" "$1"; }

echo "Папка проверки: $WORK"
# Settings of earlier test runs (linked folders, library folder) must not leak in.
defaults delete local.pero.markdown.tests 2>/dev/null || true
open -g -n --env PERO_TEST_DIR="$CMD" --env PERO_LIBRARY="$LIB" -a "$APP"
waitfor '[ "$(pc "{\"action\":\"main\"}")" != TIMEOUT ]' 60 || { echo "приложение не ответило"; exit 1; }
j rescan >/dev/null
j scope "folder:" >/dev/null

echo "Библиотека"
[ "$(state '["notes"]')" = '["Работа/План.md", "Список покупок.md"]' ] && pass "заметки найдены" || fail "заметки: $(state '["notes"]')"
[ "$(state '["tags"]')" = '["дом"]' ] && pass "теги найдены" || fail "теги: $(state '["tags"]')"

echo "Новая заметка"
menu newNote: >/dev/null
waitfor '[ -f "$LIB/Новая заметка.md" ]' && pass "⌘N создаёт файл" || fail "файла новой заметки нет"
sleep 0.5
js 'pero.insert("Встреча с Олей\nОбсудили план #работа\nвторой пункт"); return 1' >/dev/null
F="$LIB/Встреча с Олей.md"
waitfor '[ -f "$F" ]' 30 && pass "файл назван по первой строке" || fail "не переименовался: $(ls "$LIB")"
[ "$(line "$F" 1)" = "# Встреча с Олей" ] && pass "первая строка — название «# »" || fail "первая строка: $(line "$F" 1)"

echo "Формат"
js 'pero.focus(); const t = pero.getText(); pero.view.dispatch({selection: {anchor: t.indexOf("Обсудили")}}); return 1' >/dev/null
menu format: checklist >/dev/null; sleep 0.2
js 'pero.focus(); const t = pero.getText(); pero.view.dispatch({selection: {anchor: t.indexOf("второй")}}); return 1' >/dev/null
menu format: checklist >/dev/null; sleep 0.2
menu format: toggleCheck >/dev/null; sleep 0.2
js 'pero.focus(); const t = pero.getText(), i = t.indexOf("Обсудили"); pero.view.dispatch({selection: {anchor: i, head: i + 8}}); return 1' >/dev/null
menu format: highlight >/dev/null; sleep 0.2
menu format: underline >/dev/null; sleep 0.2
js 'pero.focus(); pero.view.dispatch({selection: {anchor: pero.getText().length}}); return 1' >/dev/null
menu format: divider >/dev/null; sleep 0.2
menu format: table >/dev/null
sleep 1.5
[ "$(line "$F" 2)" = "- [ ] ==<u>Обсудили</u>== план #работа" ] && pass "чек-лист, выделение и подчёркивание" || fail "строка 2: $(line "$F" 2)"
[ "$(line "$F" 3)" = "- [x] второй пункт" ] && pass "⇧⌘U отмечает пункт" || fail "строка 3: $(line "$F" 3)"
grep -q '^---$' "$F" && grep -q '^| --- | --- |$' "$F" && pass "разделитель и таблица" || fail "нет разделителя или таблицы: $(cat "$F")"
js 'pero.focus(); pero.view.dispatch({selection: {anchor: pero.getText().indexOf("второй")}}); return 1' >/dev/null
menu format: dash >/dev/null; sleep 0.8
[ "$(line "$F" 3)" = "+ второй пункт" ] && pass "⇧⌘8: список с тире" || fail "тире: $(line "$F" 3)"
js 'pero.command("undo"); return 1' >/dev/null; sleep 0.8
[ "$(line "$F" 3)" = "- [x] второй пункт" ] && pass "⌘Z отменяет команду одним шагом" || fail "после отмены: $(line "$F" 3)"

echo "Ссылка на заметку через >>"
js 'pero.focus(); pero.view.dispatch({selection: {anchor: pero.getText().length}}); pero.insert("\n"); return 1' >/dev/null
for ch in ">" ">" "С" "п" "и"; do j mainkey "$ch" keyCode=0 >/dev/null; done
sleep 0.6
j mainkey $'\r' keyCode=36 >/dev/null; sleep 1.2
grep -q '\[\[Список покупок\]\]' "$F" && pass ">> подсказывает заметку и вставляет [[Список покупок]]" || fail ">>: $(tail -2 "$F")"

echo "Закрепление, поиск, теги"
menu pinNote: >/dev/null
[ "$(state '["pinned"]')" = '["Встреча с Олей.md"]' ] && pass "заметка закреплена" || fail "закреплённые: $(state '["pinned"]')"
[ "$(state '["rows"][0]')" = '"## Закреплённые"' ] && pass "раздел «Закреплённые» сверху" || fail "строки: $(state '["rows"]')"
j search "олей" >/dev/null
[ "$(state '["rows"][1]')" = '"Встреча с Олей.md"' ] && pass "поиск находит по части слова" || fail "поиск: $(state '["rows"]')"
j search "" >/dev/null
j scope "tags:работа" >/dev/null
[ "$(state '["rows"]' | grep -c 'Встреча')" = 1 ] && pass "тег показывает свои заметки" || fail "тег: $(state '["rows"]')"

echo "Перенос, удаление, восстановление"
j scope "folder:" >/dev/null
j reveal "Встреча с Олей.md" >/dev/null
menu moveToFolder: "Работа" >/dev/null
waitfor '[ -f "$LIB/Работа/Встреча с Олей.md" ]' && pass "перенос в папку" || fail "не перенеслась"
F="$LIB/Работа/Встреча с Олей.md"
[ "$(state '["pinned"]')" = '["Работа/Встреча с Олей.md"]' ] && pass "закрепление переехало вместе с ней" || fail "закреплённые: $(state '["pinned"]')"
j reveal "Работа/План.md" >/dev/null
before=$(md5 -q "$LIB/Работа/План.md")
menu deleteNote: >/dev/null
waitfor '[ ! -f "$LIB/Работа/План.md" ]' && pass "удаление в «Недавно удалённые»" || fail "файл остался"
[ "$(state '["trash"]')" = '["Работа/План.md"]' ] && pass "заметка в корзине" || fail "корзина: $(state '["trash"]')"
j scope "trash" >/dev/null
j reveal "Работа/План.md" >/dev/null
menu restoreNote: >/dev/null
waitfor '[ -f "$LIB/Работа/План.md" ]' && [ "$(md5 -q "$LIB/Работа/План.md")" = "$before" ] && pass "восстановлена байт в байт" || fail "не восстановилась"

echo "Правки снаружи"
j scope "folder:Работа" >/dev/null
j reveal "Работа/План.md" >/dev/null
sleep 0.5
printf '# План\n\nТекст, дописанный снаружи\n' > "$LIB/Работа/План.md"
waitfor '[ "$(js "return pero.getText().includes(\"снаружи\")")" = 1 ] || [ "$(js "return pero.getText().includes(\"снаружи\")")" = true ]' && pass "открытая заметка обновилась" || fail "редактор: $(js 'return pero.getText()')"
printf 'Новая снаружи\n' > "$LIB/Работа/Снаружи.md"
waitfor '[ "$(state "[\"rows\"]" | grep -c Снаружи)" = 1 ]' && pass "новый файл появился в списке" || fail "список: $(state '["rows"]')"

echo "Пустая заметка исчезает"
menu newNote: >/dev/null; sleep 0.5
j reveal "Работа/План.md" >/dev/null; sleep 0.5
[ ! -f "$LIB/Работа/Новая заметка.md" ] && pass "брошенная пустая заметка удалена" || fail "пустая заметка осталась"

echo "Экспорт"
printf '# План\n\nТекст\n\n![Значок](../Attachments/2026/10/ab12cd-icon.png)\n' > "$LIB/Работа/План.md"
j rescan >/dev/null
out=$(j export "$OUT/План.md" path='"Работа/План.md"' format='"markdown"')
grep -q '(Attachments/2026/10/ab12cd-icon.png)' "$OUT/План.md" && [ -f "$OUT/Attachments/2026/10/ab12cd-icon.png" ] && pass "Markdown с вложением рядом" || fail "Markdown: $out $(cat "$OUT/План.md" 2>/dev/null)"
out=$(j export "$OUT/План.html" path='"Работа/План.md"' format='"html"')
grep -q 'data:image/png;base64' "$OUT/План.html" && pass "HTML одним файлом с картинкой" || fail "HTML: $out"
out=$(j export "$OUT/План.pdf" path='"Работа/План.md"' format='"pdf"')
head -c 5 "$OUT/План.pdf" | grep -q '%PDF' && pass "PDF" || fail "PDF: $out"
out=$(j export "$OUT/Встреча.txt" path='"Работа/Встреча с Олей.md"' format='"text"')
grep -q '☑ второй пункт' "$OUT/Встреча.txt" && pass "текст" || fail "текст: $out $(cat "$OUT/Встреча.txt" 2>/dev/null)"

echo "Смарт-папка и блокировка"
j smart '[{"checklists":{"_0":"someUnchecked"}}]' name='"Незакрытые"' >/dev/null
[ "$(state '["rows"]' | grep -c 'Встреча')" = 1 ] && pass "смарт-папка с фильтром чек-листов" || fail "смарт-папка: $(state '["rows"]')"
j lockSetup "1234" >/dev/null
printf '# Секрет\n\nкод от сейфа\n' > "$LIB/Секрет.md"
j rescan >/dev/null
j scope "folder:" >/dev/null
j reveal "Секрет.md" >/dev/null
menu lockNote: >/dev/null
waitfor '[ -f "$LIB/Секрет.pero-locked" ]' && ! grep -q 'сейфа' "$LIB/Секрет.pero-locked" && pass "заметка зашифрована" || fail "блокировка: $(ls "$LIB")"
j lockNow >/dev/null; sleep 0.3
[ "$(state '["session"]')" = '""' ] && pass "после «Закрыть заблокированные» текст скрыт" || fail "сессия: $(state '["session"]')"

echo "Импорт"
SRC="$WORK/src"; mkdir -p "$SRC/Папка/img" "$SRC/Папка/Вложенная"
cp examples/icon.png "$SRC/Папка/img/pic.png"
printf '# Заметка с картинкой\n\n![Картинка](img/pic.png)\n' > "$SRC/Папка/Заметка.md"
printf 'Вложенная заметка\n' > "$SRC/Папка/Вложенная/Внутри.md"
printf '<h1>Страница</h1><p>Текст <b>жирный</b> и <i>курсив</i></p><ul><li>раз</li><li>два</li></ul><table><tr><th>А</th><th>Б</th></tr><tr><td>1</td><td>2</td></tr></table>' > "$SRC/Страница.html"
printf '<html><body><p>Документ <b>RTF</b></p></body></html>' > "$WORK/rtf.html"
textutil -convert rtf "$WORK/rtf.html" -output "$SRC/Документ.rtf" 2>/dev/null
PIC=$(base64 < examples/icon.png | tr -d '\n'); HASH=$(md5 -q examples/icon.png)
cat > "$SRC/Evernote.enex" <<ENEX
<?xml version="1.0" encoding="UTF-8"?>
<en-export><note><title>Из Evernote</title><content><![CDATA[<?xml version="1.0"?><en-note><div>Текст из Evernote</div><div><en-todo checked="true"/>сделано</div><en-media type="image/png" hash="$HASH"/></en-note>]]></content><created>20240102T030405Z</created><updated>20240103T030405Z</updated><tag>архив</tag><resource><data encoding="base64">$PIC</data><mime>image/png</mime><resource-attributes><file-name>pic.png</file-name></resource-attributes></resource></note></en-export>
ENEX
r=$(j import "$SRC/Папка" folder='"Импорт"'); echo "    $r"
[ -f "$LIB/Импорт/Папка/Заметка.md" ] && [ -f "$LIB/Импорт/Папка/Вложенная/Внутри.md" ] && pass "папка Markdown со структурой" || fail "структура: $(find "$LIB/Импорт" -type f)"
grep -q '](../../Attachments/' "$LIB/Импорт/Папка/Заметка.md" && pass "картинка скопирована, путь переписан" || fail "картинка: $(cat "$LIB/Импорт/Папка/Заметка.md")"
r=$(j import "$SRC/Страница.html" folder='"Импорт"'); echo "    $r"
grep -q '^# Страница$' "$LIB/Импорт/Страница.md" && grep -q '\*\*жирный\*\*' "$LIB/Импорт/Страница.md" && grep -q '^- раз$' "$LIB/Импорт/Страница.md" && grep -q '^| А | Б |$' "$LIB/Импорт/Страница.md" \
  && pass "HTML → Markdown: заголовок, жирный, список, таблица" || fail "HTML: $(cat "$LIB/Импорт/Страница.md")"
r=$(j import "$SRC/Документ.rtf" folder='"Импорт"'); echo "    $r"
grep -q '\*\*RTF\*\*' "$LIB/Импорт/Документ.md" && pass "RTF" || fail "RTF: $(cat "$LIB/Импорт/Документ.md" 2>/dev/null)"
r=$(j import "$SRC/Evernote.enex" folder='"Импорт"'); echo "    $r"
E="$LIB/Импорт/Из Evernote.md"
grep -q 'Текст из Evernote' "$E" && grep -q '\[x\] сделано' "$E" && grep -q '#архив' "$E" && grep -q 'Attachments/' "$E" \
  && pass "Evernote: текст, задача, тег, картинка" || fail "ENEX: $(cat "$E" 2>/dev/null)"

echo "Папка с диска"
EXT="$WORK/Расшифровки"; mkdir -p "$EXT/Март" "$EXT/img"
cp examples/icon.png "$EXT/img/scan.png"
printf '# Созвон с клиентом\n\nОбсудили смету #созвон\n\n![](../img/scan.png)\n' > "$EXT/Март/Созвон.md"
printf 'Черновик в корне\n' > "$EXT/Черновик.md"
lib=$(j link "$EXT")
[ "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$lib")" = "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$EXT")" ] && pass "папка подключена и открыта" || fail "подключение: $lib"
[ "$(state '["currentNotes"]')" = '["Март/Созвон.md", "Черновик.md"]' ] && pass "файлы папки видны как заметки" || fail "заметки папки: $(state '["currentNotes"]')"
[ ! -e "$EXT/.pero" ] && [ ! -e "$EXT/.gitignore" ] && pass "в папку не добавлено служебных файлов" || fail "в папке появилось лишнее: $(ls -a "$EXT")"
j scope "folder:Март" root="\"$EXT\"" >/dev/null
j reveal "Март/Созвон.md" >/dev/null; sleep 0.5
js 'pero.focus(); pero.view.dispatch({selection: {anchor: pero.getText().indexOf("смету") + 5}}); pero.insert(" и сроки"); return 1' >/dev/null
waitfor 'grep -q "смету и сроки" "$EXT/Март/Созвон.md"' && pass "правка сохраняется прямо в файл на диске" || fail "файл: $(cat "$EXT/Март/Созвон.md")"
sleep 3
[ -f "$EXT/Март/Созвон.md" ] && pass "имя файла в папке с диска не меняется" || fail "файл переименован: $(ls "$EXT/Март")"
j search "смет" >/dev/null
[ "$(state '["rows"]' | grep -c 'Созвон')" = 1 ] && pass "поиск по подключённой папке" || fail "поиск: $(state '["rows"]')"
j search "" >/dev/null
j reveal "Март/Созвон.md" >/dev/null
j mainaction moveToFolder: "represented={\"root\": \"$(state '["root"]' | tr -d '"')\", \"folder\": \"Работа\"}" >/dev/null
waitfor '[ -f "$LIB/Работа/Созвон.md" ]' && [ ! -f "$EXT/Март/Созвон.md" ] && pass "заметка перенесена из папки с диска в библиотеку" || fail "перенос: $(ls "$LIB/Работа")"
grep -q '](../Attachments/' "$LIB/Работа/Созвон.md" && pass "картинка переехала вместе с ней" || fail "картинка: $(cat "$LIB/Работа/Созвон.md")"
j unlink "$EXT" >/dev/null
[ "$(state '["linked"]')" = '[]' ] && [ -f "$EXT/Черновик.md" ] && pass "папка отключена, файлы на месте" || fail "отключение: $(state '["linked"]')"

echo "Картинки из любых папок"
OUTSIDE="$WORK/снаружи.png"; cp examples/icon.png "$OUTSIDE"
printf '# Картинки снаружи\n\n![абсолютный путь](%s)\n\n![из дома](~/%s)\n' "$OUTSIDE" "${OUTSIDE#$HOME/}" > "$LIB/Снаружи.md"
j rescan >/dev/null; j scope "folder:" >/dev/null; j reveal "Снаружи.md" >/dev/null; sleep 1.5
loaded=$(js 'pero.blur(); await new Promise(r => setTimeout(r, 300)); return [...document.querySelectorAll(".cm-image img")].filter(i => i.complete && i.naturalWidth > 0).length')
[ "$loaded" = 2 ] && pass "картинка по абсолютному пути и через ~/ показана" || fail "загружено картинок: $loaded"

echo "Смена папки библиотеки"
NEWLIB="$WORK/Новая библиотека"; mkdir -p "$NEWLIB"
j flush >/dev/null
root=$(j switchLibrary "$NEWLIB" copy=true)
[ -f "$NEWLIB/Работа/План.md" ] && [ -d "$NEWLIB/Attachments" ] && pass "заметки скопированы в новую папку" || fail "новая папка: $(ls "$NEWLIB")"
[ "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$root")" = "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$NEWLIB")" ] && pass "Перо сразу работает с новой папкой" || fail "библиотека: $root"
[ -f "$LIB/Работа/План.md" ] && pass "прежняя папка осталась на месте" || fail "прежняя папка пропала"
LIB="$NEWLIB"

echo "Удалённая открытая заметка"
printf '# Покупки\n\nстарый текст\n' > "$LIB/Покупки.md"
j rescan >/dev/null; j scope "folder:" >/dev/null; j reveal "Покупки.md" >/dev/null; sleep 0.5
menu deleteNote: >/dev/null
waitfor '[ ! -f "$LIB/Покупки.md" ]'
printf '# Покупки\n\nхлеб\n' > "$LIB/Покупки.md"
j rescan >/dev/null; j reveal "Покупки.md" >/dev/null; sleep 0.5
js 'pero.focus(); pero.view.dispatch({selection: {anchor: pero.getText().length}}); pero.insert(" и молоко"); return 1' >/dev/null
waitfor 'grep -q "молоко" "$LIB/Покупки.md"' && grep -q "хлеб" "$LIB/Покупки.md" && ! grep -q "старый" "$LIB/Покупки.md" \
  && pass "новая заметка с тем же именем не получает текст удалённой" || fail "файл: $(cat "$LIB/Покупки.md")"

echo "Хрупкая разметка"
printf '# Хрупкая разметка\n\n<u></u> и [](https://example.com) и [[Покупки|]]\n\n![длинная\nподпись](pic.png)\n\n[Отчёт\nза квартал](q3.pdf)\n\n- [ ] задача\n' > "$LIB/Хрупкая.md"
before=$(md5 -q "$LIB/Хрупкая.md")
j rescan >/dev/null; j reveal "Хрупкая.md" >/dev/null; sleep 1
[ "$(js 'return document.querySelectorAll(".cm-task-box").length')" = 1 ] \
  && pass "оформление работает рядом с пустыми и многострочными ссылками" || fail "оформление пропало"
[ "$(md5 -q "$LIB/Хрупкая.md")" = "$before" ] && pass "файл с такой разметкой не меняется" || fail "файл изменился: $(cat "$LIB/Хрупкая.md")"

echo "Снимки"
j scope "folder:Работа" >/dev/null; j reveal "Работа/Встреча с Олей.md" >/dev/null; sleep 1
shot 1-note
menu showGallery: >/dev/null; sleep 1; shot 2-gallery; menu showList: >/dev/null
j flush >/dev/null
pc '{"action":"quit"}' >/dev/null
# Проверочная копия не должна оставаться в «Открыть с помощью» рядом с приложением из «Программ».
sleep 1; LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister; "$LSR" -u "$APP" 2>/dev/null

echo "Снимки окна: $SHOTS"
[ $FAILED = 0 ] && echo "Всё в порядке." || { echo "Есть ошибки."; exit 1; }
