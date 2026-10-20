# Omnibar: Chrome parity

Lawrence 2026-10-19 (u2573): compare the cmux-next omnibar with Chrome's and reach
parity. No flashes or lost keys while typing; after Enter the page has the keyboard,
never the omnibar; every behavior a user expects from a production omnibox.

Chrome references are Chromium `main`: `OEM` chrome/browser/ui/omnibox/omnibox_edit_model.cc,
`OVV` chrome/browser/ui/views/omnibox/omnibox_view_views.cc, `ORV`
chrome/browser/ui/views/omnibox/omnibox_result_view.cc, `AI`
components/omnibox/browser/autocomplete_input.cc, `UF` components/url_formatter/url_fixer.cc.
cmux: `CmuxNextBrowser/Omnibox/Omnibar*` (one state machine, plans/cmux-next/focus.md
section 7), `UI/AddressBarView*`, `UI/OmnibarController.swift`, `UI/OmniboxSuggestionPanel.swift`.
Both engines (Chromium and WebKit) use this one omnibar (`BrowserChromeView`).

How it was checked: the baseline build `omnibar-base-v1` (feat-cmux-next `ef7a7d84e4f`,
fleet job `c7cec5f7e22ec1a7fcca89c3`) driven with `debug.key` / `debug.omnibar` /
`debug.focus` on a Chromium tab and a WebKit tab, plus reading both sources. Tests:
`Tests/CmuxNextBrowserTests/OmnibarChromeParityTests.swift`.

Status: **match** (same behavior), **fixed** (gap closed by this work), **gap** (still
different), **n/a** (no Mac equivalent).

## Focus and commit

| Behavior | Chrome | cmux | Status |
| --- | --- | --- | --- |
| Enter loads and moves focus to the page | `OEM::AcceptInput` → `OpenMatch`; the omnibox reverts and the web contents take focus | `.ended(.commit)` → `BrowserChromeView` loads, then `onReturnFocusToPage` → focus coordinator `focusPane` (target content). Live: Chromium and WebKit tabs end with `resolved browserPage` | match; test `enterLoadsAndHandsFocusToThePage` |
| Cmd-Enter background tab, Opt-Enter / Shift-Cmd-Enter foreground tab, Shift-Enter new window | `WindowOpenDisposition` from the event flags | `OmnibarInput.Disposition(flags)`; every disposition returns focus to the page | match; test `everyCommitPathHandsFocusToThePage` |
| Ctrl-Enter adds `www.` and `.com` | desired TLD `com` (`AI`, `OEM::OnControlKeyChanged`) | none: loaded or searched the bare word | **fixed**: `.enterAddingTLD`, `OmnibarRules.desiredTLDURL` |
| Escape: revert arrowed row, close card, revert text, then blur | `OEM::OnEscapeKeyPressed` | same steps (`OmnibarReducer+Popup.escape`) | match |
| Cmd-L focuses, full URL, select all | `OVV::SetFocus(true)` | `.focusLocation` | match |
| Opt-Cmd-F / Ctrl-K focus with search keyword | `IDC_FOCUS_SEARCH` | not bound | gap (left: needs a search keyword mode) |
| Focus lost keeps typed text; next focus restores it, all selected | `OVV::OnBlur`, `SaveStateToTab` | `retainedText` | match |
| Return to a tab that was being edited restores omnibox focus | `OmniboxEditModel::RestoreState` (`focus_state`) | text restored, focus goes to the page | gap (left: needs the focus core to remember chrome focus per tab) |

## Typing

| Behavior | Chrome | cmux | Status |
| --- | --- | --- | --- |
| Typed text never overwritten by page events (commit, redirect, finish) | `OVV::Update` only while `!user_input_in_progress` | `.editing` ignores `pageURLChanged`; zero field writes while typing | match; test `typingWhileThePageNavigatesNeverRewritesTheField` (and live: 27 keys during a navigation, no reset) |
| Fast typing never drops or reorders keys | edits applied synchronously | reducer is FIFO (`OmnibarController.send` queues re-entrant inputs); stale results dropped by generation | match |
| No flash while typing: card keeps its rows | `ORV::SetMatch` updates rows in place | rows were removed and rebuilt on every delivery (twice per key with remote suggestions) | **fixed**: rows reused in place; test `theCardReusesItsRowsWhileTyping` |
| Stale rows stay until fresh ones arrive; Enter never picks a stale row | `OEM` keeps the old result until the controller updates | `popup.stale` | match |
| Inline autocomplete as a selected suffix; Backspace removes it; Right accepts | `OEM::OnAfterPossibleChange`, `OVV::OnInlineAutocompleteTextMaybeChanged` | `inlineCompletion`, `suppressCompletion` | match |
| IME composition: no completion, no field writes, Enter commits the composition | `OVV::OnBeforeUserAction`, IME handling | `marked`, applier never writes while marked | match |
| Undo / redo of edits | `Textfield` undo | own stack (`OmnibarReducer+Editing.undo`) | match |
| Loading state does not flicker the field | progress in the toolbar, not the omnibox text | reload/stop button and progress line; field untouched | match |

## Suggestions

| Behavior | Chrome | cmux | Status |
| --- | --- | --- | --- |
| Up/Down move the selection, field shows the row; Tab/Shift-Tab too | `OEM::OnUpOrDownPressed`, `OnTabPressed` | `move(_:clamp:)` | match |
| Shift-Delete removes a history row | `OEM::TryDeletingPopupLine` | `.deleteSuggestion` | match |
| History, bookmarks, open tabs (Switch to Tab), search suggestions, calculator, internal pages | providers | `OmniboxLocalIndex`, remote suggest, `OmniboxCalculator`, `OmniboxInternalPages`, Switch to Tab rows | match |
| Hover highlights only after the pointer moves | `OmniboxPopupViewViews` | `popup.pointer` | match |
| Site favicons in rows | favicon per match | kind glyph (history, bookmark, globe) | gap (left: needs the favicon store in the card) |
| Tab to search a site's engine (`youtube.com` Tab) | keyword mode for search engines | extension keywords (`chrome.omnibox`) only | gap (left) |

## URL or search

| Input | Chrome | cmux before | Status |
| --- | --- | --- | --- |
| `example.com` | https (typed-navigation upgrade, http fallback) | https, no fallback | match for https; **gap** for the http fallback when https fails (left: needs an engine load-failure hook) |
| `localhost:3000`, `127.0.0.1` | http | http | match |
| `192.168.1.20:3000`, `10.0.0.5`, `100.89.225.106:18765` (tailnet) | http (non-unique, never upgraded) | https: dev servers and routers failed | **fixed** |
| `devbox:8080`, `router/`, `router/setup` | http URL | `devbox:8080` https; `router/` searched | **fixed** |
| `nas.local`, `grafana.internal`, `*.home.arpa` | http | https | **fixed** |
| `[fd00::1]:8080` | http | https | **fixed** |
| `devbox`, `two words` | search | search | match |
| `?example.com` | search for `example.com` | searched `?example.com` | **fixed** |
| `/Users/me/a.txt`, `~/a`, `file:///…` | file URL | file URL | match |
| `javascript:`, `data:` typed | blocked from the omnibox | searched | match |
| Paste with newlines | newlines stripped (`OTU::SanitizeTextForPaste`) | newlines become spaces; wrapped URL breaks removed | match |
| Paste and Go / Paste and Search | context menu | context menu (title follows the clipboard) | match |

## Display and mouse

| Behavior | Chrome | cmux | Status |
| --- | --- | --- | --- |
| Steady-state elision (no `https://`, no `www.`), host emphasized | `OVV::UpdateSchemeStyle`, `url_formatter` | `BrowserURLDisplay` | match |
| Click selects all, second click places the caret, drag selects | `OVV::OnMousePressed/Released` | `fieldMouseDown/Up` | match |
| Full URL on any selection other than select-all | `UnapplySteadyStateElisions` | `unelide` | match |
| Copy of the whole URL copies the full URL | `OTU::AdjustTextForCopy` | `OmnibarReducer.copyContent` | match |
| Drag the location icon out as a link | `LocationIconView` drag | none | **fixed**: chip drags URL, text and title (`BrowserURLDragItem`); test `dragOutWritesTheURLTitleAndText` |
| Security chip, page info bubble | `LocationIconView`, `PageInfoBubbleView` | `PageInfoChipButton`, page info | match |
| Right-click: Undo, Cut, Copy, Paste, Paste and Go, Delete, Select All | yes | AppKit menu plus Paste and Go | match |
| Right-click: Always show full URLs; Manage search engines | yes | missing | gap (left) |

## Accessibility

| Behavior | Chrome | cmux | Status |
| --- | --- | --- | --- |
| Field is a text field with value and selection; popup is a list whose selected row is announced | `OmniboxViewViews::GetAccessibleNodeData`, `OmniboxResultView` | AX label on the field, card is an AX list, `selectedChildrenChanged` on highlight | match |
