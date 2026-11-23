# App scenes in web panels

`SceneStore` mirrors one mount's ordered scene-op batches. Pass `reset: true` to
`apply` for a replacement scene. `SceneRenderer` observes the root and each node
separately, so an update to one Row does not notify or repaint its siblings.
Scene limits match the host: 4,096 nodes and depth 64. Subtree heights and child
height frequencies are cached; attachment checks visit only the changed child
list and bounded ancestor metadata, never every existing descendant.

An app exports its render function with the mount context as its first argument:

```js
export function sessionPanel(context) {
  return Row({ title: context.cwd, symbol: "folder" });
}
```

The host calls this export with the contribution's context; the runtime currently
does not expose `cmux.app.context()`.

## Nodes, props and input

The renderer accepts the existing [scene ABI](../../../../cmux-tui/crates/cmux-app-host/js/ABI.md#scene-ops):

- VStack, HStack, ZStack and LazyVStack render child layout with `spacing`;
  vertical stacks support `alignment`. Group and ForEach place children inline.
  Reorderable with an `onMove` handler lets a person drag a row within the list.
  A drop sends the row key and its final zero-based index to the app, which owns the order.
- Text supports `text`, named or numeric `font`, `weight`, `italic`, `monospaced`, `fontDesign`
  (`rounded`, `serif`, `monospaced`: the system font's design at the same size), `strikethrough`,
  `color`, `lineLimit` and `contentTransition`. Layout uses the pane's typography and spacing tokens.
- A Text with `date` (Unix ms) and `dateStyle` (`time date timer relative offset`) ticks itself
  (`sceneDate.ts`): one shared clock, aligned to the wall-clock second and paused while the page is
  hidden, re-formats it in the page's locale and time zone (`timeZone` overrides the zone), with no
  app call and no scene batch.
- HStack `alignment` is `top`, `bottom`, `firstTextBaseline` or `lastTextBaseline` (centered by default).
- Motion (`sceneMotion.tsx`): `transition` animates a node in and out, `contentTransition` a Text's new
  content, `animation` a node's own prop changes; behind the motion gate, which crossfades under
  Reduce Motion and calm motion and draws the end state when motion is off.
- Icon accepts `symbol`, `size` and `color`. Known SF symbols map to the cmux icon
  pack; an unknown symbol uses the pack's neutral missing glyph.
- Row accepts `title`, `subtitle`, `symbol`, `tint`, `badge`, `accessory`, `unread`
  and `selected`. Badge accepts `text` and `tone`; EmptyState accepts `title`,
  `message` and `symbol`.
- Button renders its `title` or children. Menu renders nested `menu` entries with
  `title`, `symbol`, `disabled`, `destructive`, `children` or `divider`.
- TextField supports `text`, `placeholder`, `autofocus` and handler-presence props, and
  `font`, `weight`, `italic` and `monospaced` as a Text does.
- `opens` (`{chat}` or `{closed}`, the DSL's `.opens(...)`) is a tap the host runs: a New Tab page
  (NewTabAppPage `onOpen`) opens that chat or reopens that closed item in its own tab, through cmux's
  own card and Recently Closed paths; with no host `open`, the node's `onTap` runs.
- Composer (`prompt`, `placeholder`, `cwd`) is where a New Tab page app (cmux.newtab/1) shows
  cmux's own composer: NewTabAppPage gives SceneRenderer a `SceneHostContext` whose `composer`
  receives the node's element, and App.tsx portals NewTabScreen (embedded) into it. Hosts that
  give no composer draw nothing for it.
- Icon `harness:<id>` draws that agent's own mark (shared/AgentMark).
- Icon pack names an app may use as is (the full list is `agent-session/acpmux/icons/cmuxIcons.json`):
  status `status.running`, `status.needsinput`, `status.success`, `status.failure`, `status.warning`,
  `status.dot`, `unread.dot`, `unread.badge`; chats `agent.chat`, `agent.chat.new`, `agent.chat.list`,
  `agent.question`, `history.recent`; composer `composer.send`, `composer.attach`, `composer.add`;
  `search`, `filter`, `folder`, `machine.mac`, `settings`, `action.more`, `state.pinned`,
  `disclosure.expanded`, `disclosure.collapsed`. SF names the looks use map to them (SceneSymbol
  `SYMBOLS`): `bubble.left` → `agent.chat`, `square.and.pencil` → `agent.chat.new`, `magnifyingglass`
  → `search`, `arrow.up` → `composer.send`, `chevron.down`/`chevron.right` → `disclosure.*`,
  `hand.raised` → `status.needsinput`, `ellipsis` → `action.more`, `gearshape` → `settings`.
- A TextField in an HStack takes the row's free space; a Menu draws a chevron after its title.
  ProgressView renders a clamped `value` or the pane's existing spinner.
- Toggle is a settings row: `label` leading, a small switch trailing, `value` its state. Slider
  spans the row over `min...max` (0...1 when empty or reversed), snapped to `step` (a hundredth
  of the range by default) as the native renderer snaps it. Both are live only with `onChange`;
  without it they show the app's value, disabled.
- Panel groups its children on the card surface, stacked with `spacing`, under an optional
  caption `title`. `style` is `glass` (the default, the sidebar cards' veil) or `card` (a
  translucent fill with a separator hairline).
- Circle, Capsule, Rectangle and RoundedRectangle support `fill`, `stroke`,
  `strokeWidth`, `size` and `cornerRadius`. Line is a stroke along its width, `strokeWidth`
  thick in `stroke`. Spacer and Divider use native-equivalent layout roles.
- `frame({maxHeight: "infinity"})` fills the height its parent has (a stack's, or the tile's at the
  root), as `maxWidth: "infinity"` fills the width. `offset {x, y}` moves a node's drawing before
  `rotation` turns it about its center (a clock hand). A ZStack child's `position {x, y, unit?}` places
  its center in points or as a fraction of the stack, outside the stack's sizing.
- Shared decorations support `padding` (number or edge object),
  `paddingHorizontal`, `paddingVertical`, `frame`, `background`, `glass`, `hoverBackground`,
  `color`, `borderColor`, `borderWidth`, `cornerRadius`, `opacity`, `rotation`,
  `fixedSize`, `cursor`, `help`, `disabled`, `onTap` and context `menu` entries.
  Colors accept semantic ABI tokens and `#RRGGBB[AA]`, rather than arbitrary CSS.

Input dispatches `tap`, `menu {path:number[]}`, `edit {text}`, `submit {text}`,
`change {value}` (Toggle and Slider) and `cancel`, using the original node id. A Toggle flip
shows at once, and the next `value` the app sends wins. A Slider sends a value only when its
snapped value changes, so values between two snaps are dropped, never delayed; during a drag
the app's echoes do not move the thumb, and the app's value shows on release. Menu paths retain all indexes, including
dividers and nested levels. The embedding client adds its mount id and forwards
the event to `cmux.apps.panels.dispatch` synchronously from the click, key, edit
or native menu-pick handler. Do not await, queue a microtask or start a timer before
that call: the page host checks its own recent user gesture and rejects delayed
input with `cmux.app.user_only`. The page sends no gesture field.

## Status, Reload and layout

The `scene` stream also carries the mount's status, `{mount_id, status, reason?}`: `loading`,
`ready`, `failed` with the host's raw reason, or `disconnected` with a plain-words reason.
`SceneStore` reduces it with the host model's rules (`sceneStatusReducer`): a reset loads again,
the first batch with a root readies a loading mount, and a failure stays until the host or a
reset clears it. `SceneMount` draws nothing while loading, the scene once ready, and
`SceneFailure` in its place otherwise: the native failure row's words, Reload, Copy Error and
Details, or the disconnected line alone. Reload calls `cmux.apps.panels.reload` synchronously
from the click (the host accepts it only from a gesture). `SceneMount` reports its drawn height
with `cmux.apps.panels.layout {mount_id, height}`, once per change.

`cmux.apps.panels.mount` takes `surface` (`pane`, `sidebarSection`, `hoverCard`,
`sessionInfoSection` or `chatWidget`) and resolves the app's implementation as that surface's
native host does (`AppMountSurface`).

A chat widget (`cmux.chat.widget/1`) mounts in two steps, both answered by the daemon:
`cmux.apps.panels.route {key, tool}` names the extension that draws under a finished tool call
and the context its render gets (`{widget: null}` when none does), and the page mounts that answer
on the `chatWidget` surface (`chatWidgetClient.ts`, drawn by `ToolWidget.tsx`). The page does no
matching of its own.

## Bundle images

An Image's `src` is an app-bundle-relative path, such as `assets/logo.png`.
`SceneRenderer` accepts an optional `resolveAsset(path)` host adapter that returns
a trusted URL for that mounted app's bundle, or `undefined` for a missing asset.
The adapter must enforce bundle ownership, keep decoded paths inside the bundle,
and return a local resource URL; it must not fetch app-supplied network URLs.
The renderer rejects absolute paths, URLs and traversal before calling it.

Without an adapter, Image renders nothing. A mount reply with `asset_base`
(`/__appbundle/<mount_id>/`) means the page host serves that mount's bundle images:
`AppsPanelsPageProvider` answers only its own mounts, decodes each path component
once, keeps the resolved file (symlinks followed) inside the bundle and serves only
image types. The panels client's `resolveAsset` builds those URLs; without
`asset_base` it resolves nothing. Other scene nodes continue to render normally.
