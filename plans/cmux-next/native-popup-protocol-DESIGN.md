# Native popup protocol

Leo: “popovers in general need glassier bg blur / try to match liquid glass somehow”.
The native host is the popup renderer. Web code supplies typed state and action IDs;
AppKit owns the glass, layout, keyboard, editable controls and accessibility. Web code
does not mount hidden DOM rows and scrape them into a native facsimile.

The wire types are written by hand in two places that change together:
`webviews/src/ui/popupProtocol.ts` and the Swift Codable types in
`Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Overlay/PopupProtocol/`. No generator
writes them (committed generated files are refused; see
`scripts/ci/generated_files_guard.py`). The Swift protocol tests and the web popup
tests decode the same wire shapes. This local AppKit UI
protocol is separate from the pane protocol IR, which owns daemon operations,
capability scopes and MCP/CLI exposure and currently emits only TypeScript clients.
Popup action IDs are callbacks in the page, never daemon RPC names.

`useNativePopup` sends one stable popup identity with monotonically increasing
revisions. Events carry that identity and revision. Stale callbacks and owner-mismatched
hide requests cannot act on a replacement popup. Native validates action IDs against
the current declaration, including disabled state and available option values.

Rows preserve labels, descriptions, icons, shortcuts, checked/disabled state and
disabled reasons. Editable search and text fields, toggles, segmented choices, sliders,
borderless accessory actions, sections, status text and child menus are native controls.
The model's optional rail and footer keep the existing model picker's columns and
inline effort/actions; a harness choice does not become a different layout.
`railPlacement` draws the rail as each of the web picker's four harness placements
(`agentPane.display.harnessPlacement`, leo-workspace `design/model-picker.md`): `symbols`
(the default: a wrapping row of marks across the top, names only as tooltips and
accessible names, three rows then it scrolls), `top` (a wrapping strip with names),
`left` (a column with names, `railWidth` wide) and `compact` (a narrow column, each
name under its mark). A tab's `mark` is an agent brand id, drawn in the theme's text
colour in the symbols row and in the brand's colours elsewhere; `monogram` is the text
mark of a harness with no symbol. The page chooses the placement, the tabs, their marks
and the checked one; native only lays them out. Up and Down stay in the list; Left and
Right (on the list, or on an empty search field) send `navigate` with `next` or
`previous`, and the page picks the tab, except that Right on a highlighted submenu row
opens it. An action row with `children` is a model row with its effort side dropdown:
a click or Return picks it, while its trailing item (`sideLabel` and a chevron) or Right
opens the levels beside it; a row's trailing column reads controls, that item,
accessory actions, then its key. An update that would rebuild the rows while AppKit tracks a slider waits for
the release, so a drag never loses its control.

The shared `Glass.makeOverlayPanel` owns the material. A popup's transparent child
window samples behind the window on the vibrancy fallback. macOS 26 uses real Liquid
Glass. Reduce Transparency follows the existing live opaque material path. No popup
consumer supplies tint, blur, shadow or material constants. Menus open at once;
the existing closing behavior remains owned by `NativePopupHost`.

The old overflow DOM adapter remains only while consumers migrate. New native popup
consumers use typed declarations and have no production DOM fallback. Gallery
fixtures may inject a transport to inspect declarations without a native host.
