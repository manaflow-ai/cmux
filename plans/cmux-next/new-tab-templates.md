# New Tab templates (cx-yabk)

Lawrence and Leo, 2026-10-09: the New Tab page is customizable, so a user can default to a familiar view, including cmux as a terminal only. Dots at the bottom of the New Tab page switch the page in place between templates. The choice persists in cmux.json and in Settings.

## Templates

Names approved by the chief (2026-10-09). The UI copy uses only these neutral names; no other product's names, marks or assets.

| id | name | page |
| --- | --- | --- |
| `default` | Default | The B screen: field, agent rows, chat cards, Tools. |
| `composer` | Composer | One large prompt field, centered. No cards, no Tools (Codex-like layout). |
| `threads` | Threads | The field and the recent chats as a list (T3-like layout). |
| `console` | Console | A monospace field with a `>` glyph and the recent chats as lines (Claude Code-like layout). |
| `classic` | Classic | The A page: Terminal, Browser, Agent switch. |
| `terminal` | Terminal | No page: New Tab opens a terminal. |

The first four share one component (`NewTabScreen`) and its field logic: a template changes only which sections render and the CSS (`data-template`). Classic is the existing A page. The web registry is `webviews/src/agent-session/acpmux/newtab/templates.ts`.

## Setting

`tabs.newTabTemplate` in cmux.json, one of the ids above, default `default`. The Settings window shows it below "New Tab Opens" (schema row, so the UI comes from the schema). Pages may write it (agent-settable), as for `tabs.newTabKind`. When the key is unset, the page falls back to the Debug Settings tunable `newTab.layout` (`a` shows Classic), so existing dogfood setups keep working.

## Switching

The dots are on by default since cx-l1jv; Debug Settings `newTab.templateSwitcher` turns them off (it sends `templateSwitcher: true` in the page handshake, and only then do they render). The saved template applies either way. They are drawn like the sidebar's space dots: a 24px slot per dot, a hover chip, and the current template's chip sliding to the dot picked on the move token. They are native radios in a `ChoiceGroup`, so Left and Right switch templates in place and keep focus on the dots; Return opens the focused dot and Escape gives focus back to the field. A dot click re-renders the page in place (local state, no reload), gives focus back to the field, and sends `newTab.setTemplate {template}`; the host writes the setting through `SettingsController.setSetting` as `.caller("page")`. Terminal turns the page into a terminal, so arrowing onto it only focuses it; a click or Return opens it. The Terminal dot also sends `tab.open {kind: terminal}`, so the page becomes a terminal through the same replace path as a terminal choice on the page.

## Terminal routing

`newTab.default` (Cmd-T, the strip's +) resolves `tabs.newTabKind` to a kind. When that kind is the page and the template is `terminal`, `NewTabKind.resolve` returns a terminal instead, so every entrypoint that uses the shared action gets a terminal. A person's new workspace (Cmd-N, sidebar +) also starts on a terminal instead of the page (`WindowManager.createWorkspace`). The explicit `newTab.page` action and Focus Location Bar still open the page, which is the way back to the dots (plus Settings and cmux.json). The spare page pool does not prewarm while the template is `terminal`.

## Not in the prototype

Per-template defaults for which agent or project is selected, user-defined templates, and preview thumbnails on the dots.

Known limits: a dot shows its template on the current page even when the write fails (for example a managed key); later pages follow the saved setting. A Cmd-T pressed before cmux.json reloads shows the previous template.
