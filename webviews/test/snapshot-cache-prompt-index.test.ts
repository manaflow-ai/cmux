// l10n-allow-file: test fixture rows, not shipped UI.
// A pane reloaded in the same webview session (hot-apply, a dev URL, a full reload) restores the snapshot a build
// before #44398 saved, whose prompt index (`earlierPrompts`) is a list of rows. The rail now reads the index as
// columns (promptHeads.ts), so a restored list would throw while drawing. The restore leaves the index out; the
// client reads it again.
import { expect, test } from "bun:test";
import { cachedSnapshot } from "../src/agent-session/acpmux/snapshotCache";

test("a restored snapshot carries no prompt index, even one an older build saved", () => {
  const store = new Map<string, string>();
  const had = (globalThis as { sessionStorage?: unknown }).sessionStorage;
  (globalThis as { sessionStorage?: unknown }).sessionStorage = {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => void store.set(key, value),
  };
  try {
    store.set(
      "cmux.acpmux.snapshot",
      JSON.stringify({
        type: "snapshot",
        rows: [],
        sessions: [],
        earlierPrompts: [{ id: "user-3", version: 1, at: 1, kind: "user", text: "An older prompt" }],
      }),
    );
    const restored = cachedSnapshot();
    expect(restored.type).toBe("snapshot");
    expect(restored.earlierPrompts).toBeUndefined();
  } finally {
    (globalThis as { sessionStorage?: unknown }).sessionStorage = had;
  }
});
