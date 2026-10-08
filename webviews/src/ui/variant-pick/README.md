# Shared variant pick (cx-czd)

`VariantPick` owns the buttons, badge, focus movement, pending state, and errors.
Both gallery comparisons and the agent pane adapter use this exact component.

```tsx
<VariantPick
  options={[
    { id: "a", label: "A", preview: <DesignA /> },
    { id: "b", label: "B", preview: <DesignB /> },
  ]}
  recommendedId="b"
  currentPick={pick}
  onPick={async (id) => {
    await save(id);
    setPick(id);
  }}
/>
```

Options have stable, unique ids, caller-localized labels, and optional React
preview nodes. There is no option limit. The current choice is controlled;
recommending an option never chooses it. Empty options render no buttons.
Arrows wrap focus, Home/End move to the ends, Return picks, and Space uses native
button activation. Horizontal arrows follow `UiProvider` direction. Preview
controls keep their own key events. Mount under `UiProvider` and import `ui.css`.
`strings={variantPickStrings([locale])}` overrides the navigator language.
All eight UI strings are translated into the 21 pane languages in the catalog.
There is no animation and colors come only from theme tokens.

`model.ts` is pure. `PickSink.record(PickRecord)` returns a promise for a receipt:
`{ entryId | threadId, variantId, recommendedId?, who, when, note }`.
`beadsPickSink(beadId)` posts to the same-origin `/api/pick`; it omits client
`who`/`when` and accepts the server's identity/time. `recordPick` writes beads,
then passes that receipt to the feed. `noopFeedSink` deliberately does nothing;
Leo replaces it with his feed writer. A failed comment never posts to the feed.
There are no retries. Feed implementations should deduplicate their receipt and
handle their own delivery retries, so a feed failure cannot duplicate comments.
Neither sink writes `decisions.md`.

`RecordedVariantPick` adds an optional note and view-local saved choice. Key it by
entry or turn when switching contexts. It marks a pick only after both sinks
resolve. Reloading clears the view's choice; tracker comments remain authoritative.
It does not pretend the uninstalled endpoint or the no-op feed delivered anything.

## Leo's render group

Read against `feat-cmux-next-render-variants` at `f678062221e`. That branch's
`RenderGroup` maps `RenderCall` values to `RenderCard` previews and owns expanded
view state. Keep that state and the focused-card path. Replace only the compact
row with the adapter already provided in `conversation/RenderVariantsPick.tsx`:

```tsx
<RenderVariantsPick
  calls={callsWithStableToolCallIds}
  threadId={threadId}
  turnId={turnId}
  beads={beadsPickSink(relatedBeadId)}
  feed={feedSink}
  renderPreview={(call, index) => (
    <RenderCard call={{ ...call, recommended: false }} compact onExpand={() => setFocused(index)} />
  )}
/>
```

Keep tool-call ids when extracting `RenderCall`; array indexes are not stable ids.
The first `recommended: true` call supplies the single badge. Suppress the old
card badge as shown to avoid marking it twice. The adapter passes complete preview
nodes through, so expanding into the right pane and its tabs stays in Leo's lane.
Use a pane-native beads sink if the app cannot reach the gallery's same-origin
endpoint. The existing live transcript on this branch predates RenderGroup; this
change supplies and tests the adapter, without importing Leo's unrelated bundle.

This is an embedded viewer choice, not a daemon operation. CLI/MCP, palette,
settings and native shortcuts are exempt here: the common action is `onPick` and
the injected sink contract. Arrow/Return handling is scoped widget navigation.
The caller supplies options, recommendation, locale and sinks. No defaults or
runtime feature flag are introduced. The gallery contains several demonstrations.
