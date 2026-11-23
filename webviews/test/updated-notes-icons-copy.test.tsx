// l10n-allow-file: test fixtures.
// Leo 2026-11-14, on the Updated popover's blobby black Cloud glyph, its Other header with no glyph,
// and rows like "Redesign Cloud connection gates with human targets" and "The plan's Loading... waits
// 1 s, as the page's first read does": "theese are kinda crappy looking icons and stuff".
//
// Every group the popover heads draws a real symbol from the app's own set (never a filled blob,
// never blank, Other included), and no row it shows reads as an engineering note: the real nightly
// fixtures run through the same pass and every title they show must read plainly.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { AREAS } from "../src/pages/changelog/areas";
import nightlyNext50 from "../src/pages/changelog/fixtures/nightly-next-50.json";
import nightlySpan from "../src/pages/changelog/fixtures/nightly-3913596493801-span.json";
import { isJargon, plainChange } from "../src/pages/changelog/readableChange";
import { AREA_SYMBOLS } from "../src/pages/changelog/SheetPage";
import type { ReleaseNotes } from "../src/pages/changelog/types";
import type { UpdateHighlights } from "../src/pages/changelog/updateHighlights";
import { plainEntries, previewEntries } from "../src/pages/changelog/updatedPreview";
import { hasIcon } from "../src/pages/settings/icons";
import { teardownDom } from "./support/domTeardown";

/** One plain title per area (each names its area as areas.ts matches it), and one no area names. */
const AREA_TITLES: Record<string, string> = {
  sidebar: "Sidebar rows open faster",
  newTab: "New tab opens faster",
  composer: "Composer opens faster",
  cloud: "Cloud opens faster",
  agentChat: "Agent chat opens faster",
  home: "Home opens faster",
  tabs: "Tabs open faster",
  terminal: "Terminal opens faster",
  browser: "Browser opens faster",
  palette: "Command palette opens faster",
  settings: "Settings open faster",
  updates: "What's new opens faster",
  keyboard: "Shortcuts respond faster",
  panes: "Panes open faster",
  windows: "Windows open faster",
};
const LEO_LINES = [
  "Redesign Cloud connection gates with human targets",
  "The plan's Loading... waits 1 s, as the page's first read does",
];
/** Markers a shown row must never carry: builder words, measured times, PR and bead refs, stream codes. */
const MARKERS =
  /\b(?:gates?|targets?|first read|perf-\w+|cmux next|snapshot|daemon|pathspec|coalesce|provenance|watchdog|warm|spare window|signals|chunk)\b|\b\d+\s?(?:ms|s)\b|#\d{3,}|\bcx-[a-z0-9]+|Loading\.\.\./i;

const unquoted = (text: string) => text.replace(/["“][^"”]*["”]/gu, "");

function highlights(items: UpdateHighlights["items"]): UpdateHighlights {
  return {
    version: "1.0.0-nightly.4366188201001",
    build: "4366188201001",
    fromVersion: "1.0.0-nightly.4360000000001",
    fromBuild: "4360000000001",
    source: "whatsNew",
    language: "en",
    items,
    moreCount: 0,
    changelog: { from: "1.0.0-nightly.4360000000001", to: "1.0.0-nightly.4366188201001" },
  };
}

describe("the Updated popover's symbols and words", () => {
  test("every area, and Other, has a symbol from the app's own set", () => {
    for (const [area] of AREAS) expect(hasIcon(AREA_SYMBOLS[area])).toBe(true);
    expect(hasIcon(AREA_SYMBOLS.other)).toBe(true);
    expect(Object.keys(AREA_SYMBOLS).sort()).toEqual([...AREAS.map(([area]) => area), "other"].sort());
  });

  test("Leo's two rows read as what changed for the person", () => {
    expect(plainChange(LEO_LINES[0]!, undefined, "en")?.title).toBe("Cloud connects with clearer status");
    expect(plainChange(LEO_LINES[1]!, undefined, "en")?.title).toBe("Plans no longer flash a loading state");
  });

  test("builder lines fold away; imperative titles read in the past tense; other languages stay", () => {
    expect(plainChange("Avoid duplicate base archive pathspec", undefined, "en")).toBeUndefined();
    expect(plainChange("Coalesce activity bridge state pushes", undefined, "en")).toBeUndefined();
    expect(
      plainChange("Cmux NEXT perf-palette2: a color-only theme change rebuilds no terminal cells", undefined, "en"),
    ).toBeUndefined();
    expect(plainChange("Fix the tab bar jumping on close", undefined, "en")?.title).toBe(
      "Fixed the tab bar jumping on close",
    );
    expect(plainChange('A folded long thought reads "Thought for 12s"', undefined, "en")?.title).toBe(
      'A folded long thought reads "Thought for 12s"',
    );
    expect(plainChange("Cloud-Verbindung neu gestaltet", undefined, "de")?.title).toBe(
      "Cloud-Verbindung neu gestaltet",
    );
  });

  test("every title the real nightly fixtures show in the popover reads plainly", () => {
    const builds = [...(nightlyNext50 as ReleaseNotes[]), ...(nightlySpan as ReleaseNotes[])];
    let shown = 0;
    for (const build of builds) {
      const data = highlights([]);
      const { entries } = plainEntries(previewEntries(data, [build], "en"), "en");
      for (const entry of entries) {
        shown++;
        expect({ title: entry.title, jargon: isJargon(entry.title) }).toEqual({ title: entry.title, jargon: false });
        // A quoted UI string ("Thought for 12s") is what a person reads.
        expect(unquoted(entry.title)).not.toMatch(MARKERS);
        if (entry.detail) expect(unquoted(entry.detail)).not.toMatch(MARKERS);
      }
    }
    // The pass keeps the plain rows: it never empties a real update.
    expect(shown).toBeGreaterThan(20);
  });

  describe("rendered", () => {
    const scope = globalThis as Record<string, unknown>;
    const keys = [
      "window",
      "document",
      "navigator",
      "HTMLElement",
      "Element",
      "Node",
      "IS_REACT_ACT_ENVIRONMENT",
      "ResizeObserver",
      "requestAnimationFrame",
    ] as const;
    const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
    let dom: JSDOM;
    let root: Root | undefined;

    beforeAll(() => {
      dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/#/surface/updated-notes" });
      const { window } = dom;
      Object.assign(scope, {
        window,
        document: window.document,
        navigator: window.navigator,
        HTMLElement: window.HTMLElement,
        Element: window.Element,
        Node: window.Node,
        IS_REACT_ACT_ENVIRONMENT: true,
        ResizeObserver: class {
          observe() {}
          disconnect() {}
          unobserve() {}
        },
        requestAnimationFrame: () => 0,
      });
    });

    afterAll(async () => {
      act(() => root?.unmount());
      await teardownDom(saved, { window: dom.window, scope });
    });

    async function render(look: "release" | "sections") {
      const { createRoot } = await import("react-dom/client");
      const { UpdatedNotes } = await import("../src/pages/changelog/UpdatedNotes");
      const { createStrings } = await import("../src/pages/shared/i18n");
      const table = (await import("../src/pages/changelog/generated/strings.json")).default;
      const items = [
        ...Object.entries(AREA_TITLES).map(([area, title]) => ({
          id: area,
          title,
          summary: null,
          category: "improved" as const,
        })),
        { id: "other", title: "Scrolling feels smoother", summary: null, category: "fixed" as const },
        ...LEO_LINES.map((title, index) => ({ id: `leo-${index}`, title, summary: title, category: "fixed" as const })),
        { id: "jargon", title: "Avoid invisible divider occlusion holes", summary: null, category: "fixed" as const },
      ];
      act(() => root?.unmount());
      const host = dom.window.document.getElementById("root")!;
      root = createRoot(host);
      await act(async () =>
        root!.render(
          <UpdatedNotes
            data={highlights(items)}
            strings={createStrings(table)}
            actions={{ openChangelog: () => undefined }}
            mode="beside"
            look={look}
          />,
        ),
      );
      return host;
    }

    test("every group header draws an outlined symbol, Other and Maintenance included", async () => {
      const host = await render("sections");
      const heads = [...host.querySelectorAll(".wn-notes-area")];
      expect(heads.length).toBe(Object.keys(AREA_TITLES).length + 2);
      for (const head of heads) {
        const svg = head.querySelector(".wn-notes-area-icon svg.icon");
        expect({ head: head.textContent, symbol: svg !== null }).toEqual({ head: head.textContent, symbol: true });
        expect(svg!.getAttribute("fill")).toBe("none");
        expect(svg!.getAttribute("width")).toBe("16");
        expect(svg!.querySelector("path, circle, rect")).not.toBeNull();
      }
      const areas = heads.map((head) => head.closest(".wn-notes-section")!.getAttribute("data-area"));
      expect(areas).toContain("other");
      expect(areas.at(-1)).toBe("maintenance");
    });

    for (const look of ["release", "sections"] as const) {
      test(`${look}: no row reads as an engineering note`, async () => {
        const host = await render(look);
        const rows = [...host.querySelectorAll(".wn-notes-row")].map((row) => row.textContent ?? "");
        expect(rows.length).toBe(Object.keys(AREA_TITLES).length + 3);
        for (const row of rows) expect(row).not.toMatch(MARKERS);
        expect(rows).toContain("Cloud connects with clearer status");
        expect(rows).toContain("Plans no longer flash a loading state");
        const maintenance = host.querySelector(".wn-notes-maintenance-line, .wn-notes-maintenance");
        expect(maintenance?.textContent).toBe("Maintenance and fixes1");
      });
    }
  });
});
