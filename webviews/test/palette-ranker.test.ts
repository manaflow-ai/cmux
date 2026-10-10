import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { rankPalette, rankPaletteEmpty, type PaletteFrecency, type PaletteRankEntry } from "../src/palette/ranker";

const now = 800_000_000;

function entry(id: string, title: string, options: Partial<PaletteRankEntry> = {}): PaletteRankEntry & { id: string } {
  return { id, title, ...options };
}

function rankedIDs(
  entries: readonly (PaletteRankEntry & { id: string })[],
  query: string,
  frecency: PaletteFrecency = {},
) {
  return rankPalette({ entries, query, frecency, now }).flatMap((section) =>
    section.rows.map((row) => entries[row.index].id),
  );
}

describe("shared palette ranker", () => {
  test("ports the catalog queries from PaletteRankingTests", () => {
    const entries = [
      entry("action:splitRight", "Split Right"),
      entry("action:splitDown", "Split Down"),
      entry("action:closeTab", "Close Tab"),
      entry("action:newWindow", "New Window"),
      entry("action:toggleFullScreen", "Toggle Full Screen", { keywords: ["tfs"] }),
      entry("action:renameTab", "Rename Tab"),
      entry("action:newSurface", "New Surface"),
      entry("action:openSettings", "Open Settings", { keywords: ["preferences"] }),
    ];
    expect(rankedIDs(entries, "split r")[0]).toBe("action:splitRight");
    expect(rankedIDs(entries, "close tab")[0]).toBe("action:closeTab");
    expect(rankedIDs(entries, "new window")[0]).toBe("action:newWindow");
    expect(rankedIDs(entries, "tfs")[0]).toBe("action:toggleFullScreen");
    expect(rankedIDs(entries, "rename tab")[0]).toBe("action:renameTab");
    expect(rankedIDs(entries, "newSurface")[0]).toBe("action:newSurface");
    expect(rankedIDs(entries, "preferences")[0]).toBe("action:openSettings");
  });

  // Live case: typing "settings" ranked the Settings scope row (entered by its keyword) above
  // the "Settings…" action. A row whose title is the whole query comes first, ahead of a row that
  // only a keyword matches, also when that row was used more often.
  test("a row whose whole title is the query outranks a keyword-only match", () => {
    const entries = [
      entry("scope:settings", "Change Settings", {
        keywords: ["settings", "preferences"],
        frecencyKey: "scope:settings",
      }),
      entry("action:openSettings", "Settings…", {
        keywords: ["preferences", "options", "config"],
        frecencyKey: "openSettings",
      }),
      entry("action:palette.toggleSetting", "Toggle Setting…", { keywords: ["preferences"] }),
    ];
    const frecency: PaletteFrecency = { entries: { "scope:settings": { score: 20, lastUsed: now } } };
    expect(rankedIDs(entries, "settings", frecency)[0]).toBe("action:openSettings");
    expect(rankedIDs(entries, "Settings", frecency)[0]).toBe("action:openSettings");
    expect(rankedIDs(entries, "settings…", frecency)[0]).toBe("action:openSettings");
    // A partial query keeps the normal order rules.
    expect(rankedIDs(entries, "toggle")[0]).toBe("action:palette.toggleSetting");
  });

  // Live checks (nxpal-probe1, -probe2): with "Settings…" first, setting rows whose titles and
  // keywords contain "settings" pushed the scope row out of the first six. A scope row whose
  // keyword is the whole query comes right after the whole-title matches; other rows with that
  // keyword get no bonus.
  test("a scope row whose keyword is the whole query comes right after whole-title matches", () => {
    const entries = [
      entry("setting:palette.scopes.settings.prefix", "Settings Scope Prefix", { keywords: ["settings", "setting"] }),
      entry("setting:appearance.surfaces.settings.color", "Settings Background Color", {
        keywords: ["settings", "setting"],
      }),
      entry("setting:appearance.surfaces.settings.opacity", "Settings Background Opacity", {
        keywords: ["settings", "setting"],
      }),
      entry("scope:settings", "Change Settings", { keywords: ["settings", "preferences"], entersScope: true }),
      entry("action:openSettings", "Settings…", { keywords: ["preferences", "options", "config"] }),
    ];
    expect(rankedIDs(entries, "settings").slice(0, 2)).toEqual(["action:openSettings", "scope:settings"]);
  });

  test("frecency breaks ties without beating a clearly better match", () => {
    const entries = [
      entry("right", "Split Right", { frecencyKey: "right" }),
      entry("down", "Split Down", { frecencyKey: "down" }),
      entry("folder", "Open Folder", { frecencyKey: "folder" }),
      entry("weak", "Buffer Scroll Load", { frecencyKey: "weak" }),
    ];
    const frecency: PaletteFrecency = { entries: {} };
    expect(rankedIDs(entries, "split", frecency)[0]).toBe("right");
    frecency.entries!.down = { score: 5, lastUsed: now };
    expect(rankedIDs(entries, "split", frecency)[0]).toBe("down");
    frecency.entries!.weak = { score: 1000, lastUsed: now };
    expect(rankedIDs(entries, "fold", frecency)[0]).toBe("folder");
  });

  // Review of the tiered scorer: Search Tabs keeps URLs and cwds in keywords and Find in Directory
  // keeps paths in subtitles; an infix of them must still find the row.
  test("a keyword or subtitle substring still finds the row", () => {
    const entries = [
      entry("pr", "cmux pull requests", { keywords: ["https://github.com/manaflow-ai/cmux/pulls"] }),
      entry("hit", "let model = makeModel()", { subtitle: "Sources/App/FooController.swift:12" }),
      entry("other", "Open Folder"),
    ];
    expect(rankedIDs(entries, "hub")).toEqual(["pr"]);
    expect(rankedIDs(entries, "ontroller")).toEqual(["hit"]);
  });

  // 80 catalog ids start with "palette.": a plain word must not lift that namespace, while the
  // whole id, or a start written like an id, still finds its row.
  test("only an id-shaped query matches action ids", () => {
    const entries = [
      entry("copy", "Copy Tab ID", { actionID: "palette.copySurfaceID" }),
      entry("scope", "Open Palette Scope…", { actionID: "palette.open" }),
      entry("terminal", "New Terminal Tab", { actionID: "newSurface" }),
    ];
    expect(rankedIDs(entries, "palette")).toEqual(["scope"]);
    expect(rankedIDs(entries, "palette.copy")).toEqual(["copy"]);
    expect(rankedIDs(entries, "newsurface")[0]).toBe("terminal");
    expect(rankedIDs(entries, "newSur")[0]).toBe("terminal");
  });

  test("a mistyped word finds its row, below every real match", () => {
    const entries = [entry("right", "Split Right"), entry("close", "Close Tab"), entry("pane", "Close Pane")];
    expect(rankedIDs(entries, "spilt")).toEqual(["right"]);
    expect(rankedIDs(entries, "clsoe tab")[0]).toBe("close");
  });

  // Chief review of step 2: ten settings are titled "Color"; a command with the word comes first.
  // A shortcut only breaks exact ties (Split Right over the unbound Split Up), never adds score.
  test("a command beats a setting with an equal or close match, a shortcut only breaks ties", () => {
    const entries = [
      entry("setting:focusRing.color", "Color", { subtitle: "Focus Ring", demoted: true }),
      entry("setting:attention.color", "Color", { subtitle: "Attention Ring", demoted: true }),
      entry("action:workspaceColor", "Set Workspace Color…"),
      entry("action:splitUp", "Split Up"),
      entry("action:splitRight", "Split Right", { hasShortcut: true }),
      entry("action:splitTabs", "Split Tabs Evenly"),
    ];
    expect(rankedIDs(entries, "color")[0]).toBe("action:workspaceColor");
    expect(rankedIDs(entries, "split").slice(0, 2)).toEqual(["action:splitRight", "action:splitUp"]);
    const scores = rankPalette({ entries, query: "split", now }).flatMap((section) => section.rows);
    const score = (id: string) => scores.find((row) => entries[row.index].id === id)?.score;
    expect(score("action:splitRight")).toBe(score("action:splitUp"));
  });

  // The Raycast model (palette-ranking.md 5.2): the row picked for a query start goes first while
  // it matches, over better text matches; a faded or non-matching pick does not.
  test("a learned pick lifts its row while it matches and has not faded", () => {
    const entries = [
      entry("splitRight", "Split Right", { frecencyKey: "action:splitRight" }),
      entry("splitBrowser", "Split Browser Right", { frecencyKey: "action:splitBrowserRight" }),
    ];
    const week = 7 * 24 * 60 * 60;
    const picks = (score: number, lastUsed: number, last = true): PaletteFrecency => ({
      entries: {},
      pickHalfLife: week,
      picks: [{ prefix: "sp", key: "action:splitBrowserRight", score, lastUsed, last }],
    });
    expect(rankedIDs(entries, "sp")[0]).toBe("splitRight");
    expect(rankedIDs(entries, "sp", picks(3, now, false))[0]).toBe("splitBrowser");
    expect(rankedIDs(entries, "spl", picks(1, now))[0]).toBe("splitBrowser");
    expect(rankedIDs(entries, "spl", picks(1, now - 5 * week))[0]).toBe("splitRight");
    expect(rankedIDs(entries, "spl", picks(1, now, false))[0]).toBe("splitRight");
    expect(rankedIDs(entries, "split r", picks(3, now))[0]).toBe("splitBrowser");
    expect(rankedIDs(entries, "split d", picks(3, now))).toEqual([]);
  });

  // Recent of any row kind (palette-ranking.md 5.2): a workspace, tab or setting the user ran
  // shows in Recent on the empty query, although its section shows only while typing. A row that
  // matches only behind a query prefix (the picker's hidden files) never does.
  test("the empty query's Recent holds any row kind the user ran", () => {
    const entries = [
      entry("action:splitRight", "Split Right", { sectionIndex: 0, frecencyKey: "action:splitRight" }),
      entry("workspace:w3", "chatmux", {
        sectionIndex: 1,
        isVisibleWhenQueryEmpty: false,
        frecencyKey: "workspace:w3",
      }),
      entry("setting:theme", "Theme", {
        sectionIndex: 2,
        isVisibleWhenQueryEmpty: false,
        frecencyKey: "setting:theme",
      }),
      entry("hidden:.env", ".env", {
        sectionIndex: 0,
        isVisibleWhenQueryEmpty: false,
        queryPrefix: ".",
        frecencyKey: "hidden:.env",
      }),
    ];
    const result = rankPaletteEmpty({
      entries,
      sectionOrders: [0, 10, 40],
      frecency: {
        entries: {
          "workspace:w3": { score: 3, lastUsed: now },
          "setting:theme": { score: 2, lastUsed: now },
          "hidden:.env": { score: 9, lastUsed: now },
        },
      },
      now,
      showsRecent: true,
    });
    expect(result[0]?.sectionIndex).toBeNull();
    expect(result[0]?.rows.map((row) => entries[row.index].id)).toEqual(["workspace:w3", "setting:theme"]);
    const all = result.flatMap((section) => section.rows.map((row) => entries[row.index].id));
    expect(all).toEqual(["workspace:w3", "setting:theme", "action:splitRight"]);
  });

  test("frecency decays by its half-life and orders recent keys", () => {
    const store: PaletteFrecency = { entries: { a: { score: 2, lastUsed: now } }, halfLife: 100 };
    const score = (at: number) => store.entries!.a.score * 2 ** (-(at - store.entries!.a.lastUsed) / store.halfLife!);
    expect(Math.abs(score(now) - 2)).toBeLessThan(0.0001);
    expect(Math.abs(score(now + 100) - 1)).toBeLessThan(0.0001);
    expect(Math.abs(score(now + 200) - 0.5)).toBeLessThan(0.0001);
    store.entries!.b = { score: 1, lastUsed: now + 200 };
    const top = Object.keys(store.entries!).sort((left, right) => {
      const l = store.entries![left];
      const r = store.entries![right];
      return (
        r.score * 2 ** (-(now + 200 - r.lastUsed) / store.halfLife!) -
        l.score * 2 ** (-(now + 200 - l.lastUsed) / store.halfLife!)
      );
    });
    expect(top).toEqual(["b", "a"]);
  });

  test("incremental queries and a fresh scan return the same rows", () => {
    const entries = [entry("right", "Split Right"), entry("down", "Split Down"), entry("other", "Open Folder")];
    rankPalette({ entries, query: "s", now });
    rankPalette({ entries, query: "sp", now });
    const narrowed = rankedIDs(entries, "spl r");
    const fresh = rankedIDs(entries, "spl r");
    expect(narrowed).toEqual(fresh);
    expect(narrowed.length).toBeGreaterThan(0);
    expect(rankedIDs(entries, "sp")).toEqual(rankedIDs(entries, "sp"));
  });

  test("empty query shows recent first, then ordered visible sections", () => {
    const entries = [
      entry("settings", "Open Settings", { sectionIndex: 0, frecencyKey: "settings" }),
      entry("splitDown", "Split Down", { sectionIndex: 0, frecencyKey: "splitDown" }),
      entry("workspace", "api server", { sectionIndex: 1, isVisibleWhenQueryEmpty: false, frecencyKey: "workspace" }),
    ];
    const result = rankPaletteEmpty({
      entries,
      sectionOrders: [0, 10],
      frecency: { entries: { splitDown: { score: 1, lastUsed: now } } },
      now,
      showsRecent: true,
    });
    expect(result[0]?.sectionIndex).toBeNull();
    expect(result[0]?.rows.map((row) => entries[row.index].id)).toEqual(["splitDown"]);
    const all = result.flatMap((section) => section.rows.map((row) => entries[row.index].id));
    expect(all).toEqual(["splitDown", "settings"]);
    expect(new Set(all).size).toBe(all.length);
    expect(rankedIDs(entries, "api")).toContain("workspace");
  });

  test("disabled rows remain visible below enabled matches and highlights use scalar offsets", () => {
    const entries = [entry("enabled", "Split Right"), entry("disabled", "Split Down", { isEnabled: false })];
    const result = rankPalette({ entries, query: "split", now, highlightLimit: 1 });
    expect(result[0]?.rows.map((row) => entries[row.index].id)).toEqual(["enabled", "disabled"]);
    expect(result[0]?.rows[0]?.highlights).toEqual([0, 1, 2, 3, 4]);
    expect(result[0]?.rows[1]?.highlights).toEqual([]);
  });

  test("the built JavaScriptCore bridge exposes the same ranker", async () => {
    // The bridge is build output (scripts/cmux-next/build-web-bundles.sh), not a committed file:
    // build it into a scratch directory, as the app build does into the package resources.
    const out = mkdtempSync(join(tmpdir(), "palette-ranker-"));
    const built = Bun.spawnSync(["sh", "../scripts/cmux-next/build-palette-ranker.sh", "--out", out]);
    expect(built.exitCode).toBe(0);
    const bundlePath = join(out, "palette-ranker.js");
    const bundle = await Bun.file(bundlePath).text();
    expect(bundle.length).toBeGreaterThan(0);
    await import(bundlePath);
    const bridge = (globalThis as typeof globalThis & { __cmuxPaletteRank?: (request: string) => string })
      .__cmuxPaletteRank;
    expect(typeof bridge).toBe("function");
    const sections = JSON.parse(
      bridge!(
        JSON.stringify({
          operation: "rank",
          entries: [entry("right", "Split Right"), entry("down", "Split Down")],
          query: "split r",
          sectionOrders: [],
          frecency: { entries: {} },
          now,
          showsRecent: false,
          keepsSectionOrder: false,
          ranksPrefixFirst: false,
          recentLimit: 5,
          rowLimit: 400,
          highlightLimit: 60,
        }),
      ),
    ) as Array<{ rows: Array<{ index: number }> }>;
    expect(sections[0]?.rows[0]?.index).toBe(0);
  });
});
