// The page's interface language, set by the shell through configure({lang}).
// Russian is the source: t() takes the Russian text and returns it in Russian,
// or its English version for any other language.
let lang = "ru"

const english = {
  "Начните писать…": "Start writing…",
  "Выполнено": "Checked",
  "Не выполнено": "Unchecked",
  "Картинка из интернета не загружается: ": "Can’t load the image from the internet: ",
  "Нет картинки: ": "Image not found: ",
  "Изменить размер": "Resize",
  "Открыть вложение": "Open attachment",
  "Свернуть раздел": "Collapse section",
  "Развернуть раздел": "Expand section",
  "Без названия": "Untitled",
  "Вставка": "Pasted Image",
  "мин чтения": "min read",
}

export function setLang(value) { lang = value }

export const getLang = () => lang

export const t = (text) => (lang === "ru" ? text : english[text] ?? text)
