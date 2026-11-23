# Profile files beside their manifest

A profile or setup can keep a stylesheet, theme or views script as a separate
text file. In `files`, an inline string still means its contents. An object
containing only `$file` reads a file relative to the manifest's directory:

```json
{
  "cmuxProfile": 1,
  "name": "my-look",
  "settings": { "appearance.themeFile": "my-look" },
  "files": {
    "themes/my-look.json": { "$file": "assets/theme.json" },
    "agent-pane/theme.css": { "$file": "assets/chat.css" },
    "keybindings.json": "[]"
  }
}
```

Preview it with `cmux customize use ./profile.json`. Keep the preview with
`cmux customize apply`, or restore the previous files with `cmux customize discard`.
The same `files` syntax works in `cmux-setup.json` for setup installation. Direct
`cmux customize use ./cmux-setup.json` previews its settings and files, including
files at conventional setup paths. Setup actions and extension installation still
belong to `cmux setup install`.

References are opt-in: a string such as `"assets/theme.json"` remains literal text.
Source paths use the existing package path rules: relative ASCII components made
of letters, digits, `.`, `_` and `-`, with no dot segments, `.git`, leading hyphens
or links. Paths are at most 512 bytes and components at most 128 bytes. Sources
must be regular UTF-8 files at most 2 MiB. Missing files, directories, traversal,
absolute paths, links and malformed reference objects are refused before preview
writes any live files. Referenced text receives the same destination and content
validation as inline text.

Put sources outside a setup's conventional destination folders, such as `assets/`:
a destination declared in `files` and also supplied by the setup's folder scan
remains a duplicate error. A saved or exported profile embeds the resolved text,
so it stays portable without the original source folder. Setup content hashes
include the resolved text, so changing a source changes the setup's identity.

The import boundary resolves references once for both readers. The behavioral
detector is `cmux-customize/tests/file_refs.rs`; run it with the rest of that crate
through `cmux-ci test -- cargo test -p cmux-customize` from `cmux-tui/`. It covers
preview/discard, setup install, portable export, source changes, invalid paths,
links, size and encoding limits, and validation before any live write.
