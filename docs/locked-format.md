# Locked-note format

**English** · [Русский](locked-format.ru.md)

A locked note is a file `Title.pero-locked` next to the regular `.md` files. The format is open: a note can be decrypted without the app, with [`tools/decrypt-locked.swift`](../tools/decrypt-locked.swift):

```bash
swift tools/decrypt-locked.swift ~/Library/Application\ Support/Pero/Library/.pero/lock.json Secret.pero-locked
```

The script asks for the password (or reads it from standard input) and prints the note’s Markdown.

## Keys

All encryption is AES-256-GCM without additional authenticated data (AAD). Every encrypted block is stored in CryptoKit’s “combined” form: a 12-byte nonce, then the ciphertext, then the 16-byte tag.

1. **Password key.** PBKDF2-HMAC-SHA256 of the UTF-8 password, a random 16-byte salt, 600,000 iterations (the number is read from `lock.json`), a 32-byte key.
2. **The library’s master key**: 32 random bytes, encrypted with the password key. Changing the password re-encrypts only this key; notes are untouched.
3. **A note key**: 32 random bytes of its own for every note, encrypted with the master key.
4. **The note’s text** is encrypted with the note key.

For Touch ID the master key is stored in the macOS keychain: service `local.pero.markdown.locked-notes`, account = the path of the library folder.

## `lock.json`

Lives in the main library’s data folder: `<library>/.pero/lock.json`. Notes in folders connected from disk are locked with the same password and the same master key.

```json
{
  "version": 1,
  "iterations": 600000,
  "salt": "<base64, 16 bytes>",
  "wrappedMasterKey": "<base64, combined: the master key under the password key>",
  "hint": "a hint, or absent"
}
```

## `.pero-locked`

```json
{
  "format": "pero-locked",
  "version": 1,
  "title": "The note’s title in plain text, as in Apple Notes",
  "wrappedKey": "<base64, combined: the note key under the master key>",
  "ciphertext": "<base64, combined: JSON {\"text\": \"…Markdown…\"} under the note key>"
}
```

The title stays readable, as in Apple Notes: it shows in the note list without the password. A note with attachments can’t be locked — only the text is encrypted.
