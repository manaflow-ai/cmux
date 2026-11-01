# Omnibar: Chromium parity matrix

Lawrence 2026-10-30 (msg 17798): audit the cmux-next browser omnibar against Chromium's omnibox and
match its behavior fully: new tabs, clicks, focus. Follow-up (msg 17829): a click outside the
omnibar (the page, the New Tab page) must blur it as Chromium does.

This file is the audit. [plans/cmux-next/omnibar-parity/PARITY.md](../plans/cmux-next/omnibar-parity/PARITY.md)
holds the earlier pass (2026-10-19: commit, typing, suggestions, URL-or-search, elision); rows it
already closed are not repeated here except where this audit found a new gap.

## Sources

Chromium `main` (fetched 2026-10-30):

| Short | File |
| --- | --- |
| `OVV` | chrome/browser/ui/views/omnibox/omnibox_view_views.cc |
| `OEM` | chrome/browser/ui/omnibox/omnibox_edit_model.cc |
| `BV` | chrome/browser/ui/views/frame/browser_view.cc |
| `BC` | chrome/browser/ui/browser_commands.cc |
| `TF` | ui/views/controls/textfield/textfield.cc |
| `CEF` | chromiumembedded/cef libcef/browser/chrome/chrome_browser_host_impl.cc |

cmux: `CmuxNextBrowser/Omnibox/Omnibar*` (the pure state machine), `CmuxNextBrowser/UI/AddressBarView*`
(the field, its AppKit callbacks), `CmuxNextApp/Focus/*` (focus coordinator, effect applier,
`OmnibarFocusMemory`), `CmuxNextBrowser/CEF/CEFTab+Focus.swift` (Chromium page focus requests).

Gap column: **match**, **gap** (to fix, slice named), **fixed** (closed by this work, sha in
the slice table), **differs by choice** (with the reason), **n/a** (no Mac equivalent).

## Focus in and out

| Behavior | Chromium | cmux | Gap |
| --- | --- | --- | --- |
| A click on the page (or anywhere focusable outside the omnibox) blurs it: the caret and the selection highlight go, the popup closes, typed text stays in the box | `OVV::OnBlur` (popup closed, `saved_selection_for_focus_change_` kept, text kept while `user_input_in_progress`), `TF::OnBlur` hides the selection | before a tab's first real page (the New Tab page, a blank page) Chromium's page window is cut out over the whole page (`CEFTab.applyOcclusion`), so the press landed on the pane's `CEFHostView`, which took no focus: the field editor kept caret, selection and suggestions. Now the press makes the host view first responder; the edit ends with its text kept and the focus model gives the page the keyboard. A press on a real page goes to Chromium's page window, which already blurred the omnibar (`ChildWindowKeyRule` chosen page) | **fixed**: slice 1 |
| Blur keeps edited text; text equal to the permanent text reverts | `OVV::OnBlur` (`RevertAll` when edited text equals `GetPermanentDisplayText`) | `focusLost` keeps `retainedText` unless empty or equal to the display text | match |
| Blur by switching apps or windows changes nothing | `OVV::OnBlur` reverts only when "blurred in favor of some other View in the same Widget" | the field editor stays first responder of a window that is not key: no `focusLost` | match |
| Focus coming back by Tab or a tab return restores the selection the blur saved; a click and Cmd-L select all | `OVV::OnFocus` (`saved_selection_for_focus_change_`), `OVV::OnTabChanged` | `OmnibarState.savedSelection`; the tab return calls `AddressBarView.restoreFocus()` | **fixed**: slice 3 |
| A click that focuses selects all on release; a drag keeps its own selection | `OVV::OnMousePressed` / `OnMouseReleased` (`select_all_on_mouse_release_`) | `fieldMouseDown` / `fieldMouseUp` | match |
| Typing while the focusing press is still down does not lose the typed characters | `OVV::HandleKeyEvent` end: select-all at once (crbug.com/40123188) | AppKit's text tracking loop holds key events until the release, so the typed key lands after the select-all and replaces it | match |
| Cmd-L: focus, unelide, select all, even when already focused; leaves keyword mode | `OVV::SetFocus(true)` (`Unelide`, `ClearKeyword` when already focused) | `focusLocation` leaves the keyword session first | **fixed**: slice 4 |
| Leaving keyword mode (Backspace at the start, Cmd-L) puts back the keyword alone after a bare Tab entry, the keyword and a space after typed text or a space entry, nothing after a shortcut entry | `OEM::ClearKeyword` (`keyword_mode_entry_method_`) | keyword with no space, always | **fixed**: slice 4 |
| Escape: revert arrowed row, close popup, revert and select all, then focus the page | `OEM::OnEscapeKeyPressed` | `OmnibarReducer+Popup.escape` | match |
| Enter: load, then the page has focus | `OEM::OpenMatch` | `.ended(.commit)` → `onReturnFocusToPage` | match |

## Layout while focusing

| Behavior | Chromium | cmux | Gap |
| --- | --- | --- | --- |
| A focusing click or Cmd-L moves nothing: chip, text, star, padding and height keep their frames | the security chip keeps its text while focused and drops it only for user input (`LocationIconView::GetShowText` -> `OmniboxView::IsEditingOrEmpty`) | the chip dropped its label ("Not secure", "File", "cmux") at focus, so the field and its text moved left by the label's width (msg 18159). Now the focused, untouched omnibar keeps the resting chip | **fixed**: slice 2 |
| Typing replaces the chip with the input's icon | same rule (`IsEditingOrEmpty`) | `.input` chip while editing | match |

## New tabs

| Behavior | Chromium | cmux | Gap |
| --- | --- | --- | --- |
| A new tab on the New Tab page focuses the omnibox, text empty | `WebContentsDelegate::ShouldFocusLocationBarByDefault` (NTP), `BV::OnActiveTabChanged` → `RestoreFocus` | the new tab's address bar is the focus target | match |
| A page load that asks for focus does not take it from the omnibox of a new tab; typing before the NTP loads is never overwritten | `OVV::SetFocus(false)` does not select-all when already focused (crbug.com/40610912); `CEF` asks `OnSetFocus(NAVIGATION)` after the first load | `CEFTab.chromiumRequestsFocus` refuses CEF's own requests | match |
| A click on the New Tab page moves focus to the page | the NTP is web contents: the click focuses them, `OVV::OnBlur` | see the first row | **fixed**: slice 1 |
| Switching back to a tab restores its omnibox edit: text, keyword, focus, selection | `OEM::GetStateForTabSwitch`, `OEM::RestoreState`, `OVV::OnTabChanged` (`SetSelectedRange(state->selection)`) | per-tab `AddressBarView` keeps its state; `OmnibarFocusMemory` gives focus back with the saved selection | **fixed**: slice 3 |
| A tab left with all its text deleted comes back reverted and all selected | `OEM::GetStateForTabSwitch` (empty `user_text`), `OVV::OnTabChanged` | `focusLost` drops empty text: reverted, select-all on the next focus | match |

## Mouse in the field

| Behavior | Chromium | cmux | Gap |
| --- | --- | --- | --- |
| Second click in a focused field places the caret; double-click a word; triple-click all | `TF` / `SelectionController` | field editor | match |
| Double-click whose first click unelided selects the first click's word | `OVV::OnMousePressed` (crbug.com/40693090) | `doubleClickWord` | match |
| Right-click on the unfocused field selects all at the press | `PlatformStyle::kSelectAllOnRightClickWhenUnfocused` (Mac) | `fieldMouseDown` right button | match |
| A press with the popup open never re-arms select-all | `OVV::OnMousePressed` (`!is_popup_open`) | `focusing` is false while focused | match |
| Dropping a URL or text on the omnibox puts it in the box, focused and all selected; it does not load | `OVV::PerformDrop` (`SetUserText`, `RequestFocus`, `SelectAll`; `StripJavascriptSchemas`, `CollapseWhitespace`) | took no drop at rest; while editing the field editor inserted the drop at the pointer. Now `AddressBarView.acceptDrop(from:)` (bar and field editor) sends `.dropped`, which replaces the text, all selected | **fixed**: slice 5 |

## Suggestions on focus

| Behavior | Chromium | cmux | Gap |
| --- | --- | --- | --- |
| A focusing click, Cmd-L, or focus on an empty New Tab omnibox asks for zero-prefix suggestions | `OEM::StartZeroSuggestRequest` from `OVV::SetFocus(true)` and `OVV::OnMouseReleased`; the rows come from `ZeroSuggestProvider`, Google's remote zero-suggest service (signed-in, Google as the engine); with no answer the popup stays closed | no rows until the user types; the New Tab page shows its own rows | **differs by choice**: cmux has no zero-suggest service, and local rows on focus would be a cmux invention, not Chromium's behavior. Revisit if a zero-suggest endpoint is added |

## Slices

Each slice: a failing test first, then the fix, fleet runs before and after, rebased on
`feat-cmux-next`, plain push.

| Slice | What | Commits | Evidence |
| --- | --- | --- | --- |
| 1 | A click outside (the page, the New Tab page) blurs the omnibar | landed in 463e538ef941..a06031fa83c4; tested as 8be3536d / a940077d | red step 27ae34304f9711e8650a73ea fails "isEditing"; green step 14d2083ddee9081573b88af0 (20 tests, 5 suites) |
| 2 | Focusing moves nothing (chip label kept) | landed in 463e538ef941..a06031fa83c4; tested as fe671fbc / 5a4175aa | red step e90a6d197ad4dd1c7a6bbded fails 5 tests (chip 24 pt after focus); green step 3ad52ed3793d537d9f801910 (63 tests, 11 suites); compile f0a7dc506f07e53c2a555603 |
| 3 | Focus by Tab and tab return restore the saved selection | landed in dc0fd32ab02e..6e2b8c8dba82 | red step 57f27d4720cde76fe7e0ecac fails ({0,3} for {1,0}); green step b963abca86140cc6e93f4daf (its omnibar suites pass; OmnibarDropTests was slice 5's); compile 8b5796b0f84adc5b1937fec8 |
| 4 | Cmd-L and Backspace leave keyword mode as `ClearKeyword` does | landed in 463e538ef941..a06031fa83c4; tested as d8c0f45f / 5faef087 | red step c0c919e0cec0edb0013e5534 fails 4 tests; green step 85b3f29fa338cd82e14b4277 (30 tests) |
| 5 | Drop on the omnibar | landed in 0779a9459c5a..94eaf0f9f821 | red step 7cc41aa3d6e402278a19aad3 (no `.dropped`, no `acceptDrop`); green step d69008c1b60d89fda600958d (33 tests, 5 suites); compile 02dc89f066b9ac8c92c41df1 |
| 6 | Zero-prefix suggestions on focus | none (differs by choice, see the table) | n/a |
