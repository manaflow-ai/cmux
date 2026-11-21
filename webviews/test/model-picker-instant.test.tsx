import { describe, expect, test } from "bun:test";

// Leo 2026-11-08 (a video of the composer's model menu opening with no models): "why is there no
// models … this shouldn't be so slow to load in. we know what the models are." Before acpmux listed
// its harnesses, every bundled catalog harness read as Not installed and none of its models was
// pickable; OpenCode's probed list was lost to its `default` placeholder on every fetch.

const harness = (id: string, installed: boolean) => ({
  id,
  name: id,
  brand: id,
  acpmuxHarness: installed ? id : null,
  installed,
  pickable: true,
  models: [{ id: `${id}-model`, name: `${id} model`, shortName: `${id} model` }],
});

describe("the model menu before acpmux lists its harnesses", () => {
  test("bundled catalog harnesses are pickable, none Not installed", async () => {
    const { composerPickerEntries } = await import("../src/agent-session/acpmux/composerPickerEntries");
    const catalog = { harnesses: [harness("claude", false), harness("codex", false)], provisional: true };
    const before = composerPickerEntries({ catalog: [], summary: undefined } as never, catalog as never, false);
    expect(before.map((entry) => [entry.id, entry.pickable, entry.notInstalled])).toEqual([
      ["claude", true, undefined],
      ["codex", true, undefined],
    ]);
    // Once acpmux has answered, a harness it does not run is Not installed, as before.
    const after = composerPickerEntries({ catalog: [], summary: undefined } as never, catalog as never, true);
    expect(after.map((entry) => [entry.id, entry.pickable, entry.notInstalled])).toEqual([
      ["claude", false, true],
      ["codex", false, true],
    ]);
  });

  test("the face draws the first catalog harness before the list", async () => {
    const { composerHealthHarness } = await import("../src/agent-session/acpmux/composerPickerEntries");
    const catalog = { harnesses: [harness("claude", false)], provisional: true };
    expect(composerHealthHarness({ catalog: [], summary: undefined } as never, catalog as never, false)).toBe("claude");
  });

  test("a harness reporting only its default placeholder keeps its cached models", async () => {
    const { HarnessCatalogCache } = await import("../src/agent-session/acpmux/catalog");
    const store = new Map<string, string>();
    const storage = {
      getItem: (key: string) => store.get(key) ?? null,
      setItem: (key: string, value: string) => void store.set(key, value),
    } as unknown as Storage;
    const probed = [{ id: "opencode/gpt-6", name: "GPT-6" }];
    new HarnessCatalogCache(() => storage).merge([{ id: "opencode", name: "OpenCode", models: probed }] as never, 1);
    const merged = new HarnessCatalogCache(() => storage).merge(
      [{ id: "opencode", name: "OpenCode", models: [{ id: "default", name: "Default" }] }] as never,
      2,
    );
    expect(merged[0]!.models).toEqual(probed);
  });
});
