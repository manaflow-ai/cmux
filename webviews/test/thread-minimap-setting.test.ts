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
import { rankPalette, type PaletteRankEntry } from "../src/palette/ranker";
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

// The palette's settings rows as SettingsPaletteSource and SettingsPaletteProvider build them: the
// title, the group as subtitle, the value as accessory, and the keywords plus the key, the section,
// the group and "setting"; demoted under commands. The palette ranks them with this ranker (the
// native palette runs the same code through PaletteRankerBridge).
const sectionTitle = new Map(schema.sections.map((section) => [section.id, section.title.text]));
const rows = schema.rows.filter((row) => row.consumers.includes("cmux-next"));
const entries: PaletteRankEntry[] = rows.map((row) => ({
  title: row.title.text,
  subtitle: row.group.text,
  accessory: row.choices?.find((choice) => choice.value === row.default)?.title.text ?? null,
  keywords: [...row.keywords, row.key, sectionTitle.get(row.section) ?? row.section, row.group.text, "setting"],
  demoted: true,
}));
const palette = (query: string) =>
  rankPalette({ entries, query, sectionOrders: [0], now: Date.now(), showsRecent: false })
    .flatMap((section) => section.rows)
    .map((row) => rows[row.index]!.key);

describe("the palette finds it", () => {
  for (const query of ["TICK RAIL", "tick rail", "wave rail", "prompt rail", "scroll rail", "thread minimap"])
    test(`"${query}" ranks the Chat Minimap row first`, () => {
      expect(palette(query)[0]).toBe(MINIMAP_KEY);
    });

  test(`"minimap" lists it in the top three`, () => {
    expect(palette("minimap").slice(0, 3)).toContain(MINIMAP_KEY);
  });
});

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
