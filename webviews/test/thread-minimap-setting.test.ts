// Leo, 2026-10-22, searching the command palette for "TICK RAIL" and getting No Results: "doesn't
// show as an option". The chat's edge (the prompt rail of ticks, the full map, or nothing) is one
// setting, Settings > Agent Chat > Chat Minimap (`agentPane.display.minimap`), whose values are the
// `thread-minimap-layout` experiment's arms and whose default is its default arm, so the row never
// says one thing while the chat shows another. The palette and Settings search find it under the
// words people use for it.
import { afterAll, describe, expect, test } from "bun:test";
import exported from "../../schemas/settings/settings-schema.json";
import { threadMinimapLayout } from "../src/agent-session/acpmux/threadMinimap/layout.experiment";
import { MINIMAP_KEY, resolveThreadMinimapArm } from "../src/agent-session/acpmux/chatDisplay";
import { armIds } from "../src/experiments/experiment";
import { installDom } from "../src/pages/settings/testDom";

type Text = { text: string; key: string | null };
type Row = {
  key: string;
  kind: string;
  title: Text;
  group: Text;
  section: string;
  keywords: string[];
  consumers: string[];
  choices?: { value: string; title: Text }[];
  default?: unknown;
};
const schema = exported as unknown as { rows: Row[]; sections: { id: string; title: Text }[] };
const minimap = schema.rows.find((row) => row.key === MINIMAP_KEY);

describe("the Chat Minimap row is the experiment's arms", () => {
  test("a choice of every arm, and no other value", () => {
    expect(minimap?.kind).toBe("choice");
    expect((minimap?.choices ?? []).map((choice) => choice.value).sort()).toEqual(armIds(threadMinimapLayout).sort());
  });

  test("its default is the experiment's default arm", () => {
    expect(minimap?.default).toBe(threadMinimapLayout.defaultArm);
  });

  test("the page takes an arm from the key and leaves anything else to the experiment", () => {
    for (const arm of armIds(threadMinimapLayout)) expect(resolveThreadMinimapArm({ [MINIMAP_KEY]: arm })).toBe(arm);
    expect(resolveThreadMinimapArm({})).toBeNull();
    expect(resolveThreadMinimapArm({ [MINIMAP_KEY]: "wave-2" })).toBeNull();
  });

  // The key was an on/off toggle before it was this choice: `true` drew the full map and `false` left
  // the chat to the experiment. A settings file the toggle wrote keeps meaning the same thing.
  test("a value the old toggle wrote keeps its meaning", () => {
    expect(resolveThreadMinimapArm({ [MINIMAP_KEY]: true })).toBe("full");
    expect(resolveThreadMinimapArm({ [MINIMAP_KEY]: false })).toBeNull();
  });
});

// The palette ranks these rows in Rust: cmux-tui/crates/cmux-palette-ranker/tests/settings_rows.rs.

describe("Settings search finds it", () => {
  const restore = installDom();
  afterAll(() => restore());
  for (const query of ["tick rail", "wave", "prompt rail", "minimap"])
    test(`"${query}"`, async () => {
      const { searchRows } = await import("../src/pages/settings/search");
      const keys = searchRows(query, () => undefined).flatMap((group) => group.rows.map((row) => row.key));
      expect(keys).toContain(MINIMAP_KEY);
    });
});
