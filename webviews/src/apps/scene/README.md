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
  Reorderable has the native renderer's current stack layout; list drag handling
  is not yet implemented in either renderer.
- Text supports `text`, named or numeric `font`, `weight`, `italic`, `monospaced`,
  `color` and `lineLimit`. Layout uses the pane's typography and spacing tokens.
- Icon accepts `symbol`, `size` and `color`. Known SF symbols map to the cmux icon
  pack; an unknown symbol uses the pack's neutral missing glyph.
- Row accepts `title`, `subtitle`, `symbol`, `tint`, `badge`, `accessory`, `unread`
  and `selected`. Badge accepts `text` and `tone`; EmptyState accepts `title`,
  `message` and `symbol`.
- Button renders its `title` or children. Menu renders nested `menu` entries with
  `title`, `symbol`, `disabled`, `destructive`, `children` or `divider`.
- TextField supports `text`, `placeholder`, `autofocus` and handler-presence props.
  ProgressView renders a clamped `value` or the pane's existing spinner.
- Circle, Capsule, Rectangle and RoundedRectangle support `fill`, `stroke`,
  `strokeWidth`, `size` and `cornerRadius`. Spacer and Divider use native-equivalent
  layout roles.
- Shared decorations support `padding` (number or edge object),
  `paddingHorizontal`, `paddingVertical`, `frame`, `background`, `hoverBackground`,
  `color`, `borderColor`, `borderWidth`, `cornerRadius`, `opacity`, `rotation`,
  `fixedSize`, `cursor`, `help`, `disabled`, `onTap` and context `menu` entries.
  Colors accept semantic ABI tokens and `#RRGGBB[AA]`, rather than arbitrary CSS.

Input dispatches `tap`, `menu {path:number[]}`, `edit {text}`, `submit {text}` and
`cancel`, using the original node id. Menu paths retain all indexes, including
dividers and nested levels. The embedding client adds its mount id and forwards
the event to `cmux.apps.panels.dispatch` synchronously from the click, key, edit
or native menu-pick handler. Do not await, queue a microtask or start a timer before
that call: the page host checks its own recent user gesture and rejects delayed
input with `cmux.app.user_only`. The page sends no gesture field.

## Bundle images

An Image's `src` is an app-bundle-relative path, such as `assets/logo.png`.
`SceneRenderer` accepts an optional `resolveAsset(path)` host adapter that returns
a trusted URL for that mounted app's bundle, or `undefined` for a missing asset.
The adapter must enforce bundle ownership, keep decoded paths inside the bundle,
and return a local resource URL; it must not fetch app-supplied network URLs.
The renderer rejects absolute paths, URLs and traversal before calling it.

Without an adapter, Image renders nothing. The current Session Info page contract
does not expose bundle resources, so it intentionally passes no adapter until
its host provides that route. Other scene nodes continue to render normally.
