# Visible UI change: a gallery snapshot of every state

**Proves:** the change looks as intended in each state it can show (empty, one, many, long text, error, loading,
dark and light, narrow and wide), and it does not move pixels elsewhere.

**The minimal check:**
1. Add or extend a gallery entry (`webviews/src/gallery`, listed in `ENTRIES.md`) with each state as a fixture:
   no network, a fixed clock (`gallery/clock.ts`), fixed data.
2. Snapshot each state; the gallery suites (`web-browser` job) compare against the base.
3. Swift views: a matrix entry under `scripts/gallery-matrix` or a snapshot test in the module's Tests target.
4. Interaction: a Playwright step that clicks the new control and asserts the visible result, not a class name.
5. Show it: before/after pictures in the PR body (`scripts/gallery-compare.sh`).

```tsx
// webviews/src/gallery/entries/composer-status.tsx
export default entry("Composer status", {
  empty: () => <ComposerStatus items={[]} />,
  many: () => <ComposerStatus items={fixtures.items(40)} />,
  longText: () => <ComposerStatus items={[fixtures.item({ title: "x".repeat(400) })]} />,
  error: () => <ComposerStatus items={[]} error="Disconnected" />,
});
```

Copy from: `webviews/src/gallery` and `scripts/gallery-compare.sh`.
