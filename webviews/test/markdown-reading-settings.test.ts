// The markdown viewer's Reading Settings (user 2026-10-19: "make it easier to adjust tons of
// settings in markdown viewer like max width"): each popover row is one `markdown.*` key, its CSS
// variable follows at once, a slider drag writes the settings file once, and Reset removes the keys.
import { describe, expect, test } from "bun:test";
import {
  MARKDOWN_READING,
  MARKDOWN_STYLE_DEFAULTS,
  MARKDOWN_WIDTH_PRESETS,
  applyMarkdownLook,
  clampWidth,
  markdownWidthPreset,
  parseWidthInput,
  markdownBehavior,
  markdownReadingValues,
  markdownStyleVariables,
} from "../src/pages/markdown/settings";
import { MarkdownStore, withMarkdownSetting, type Schedule } from "../src/pages/markdown/store";
import type { PageClient } from "../src/pages/shared/pageClient";

describe("reading settings to CSS", () => {
  test("the text width is in characters; full width lifts it; maxWidth still works alone", () => {
    expect(markdownStyleVariables({ layout: { width: 90 } })["--cmux-md-content-width"]).toBe("90ch");
    expect(markdownStyleVariables({ layout: { width: 90, fullWidth: true } })["--cmux-md-content-width"]).toBe("none");
    expect(markdownStyleVariables({ layout: { maxWidth: "60rem" } })["--cmux-md-content-width"]).toBe("60rem");
    expect(markdownStyleVariables({ layout: { width: 90, maxWidth: 400 } })["--cmux-md-content-width"]).toBe("90ch");
    expect(markdownStyleVariables({})["--cmux-md-content-width"]).toBeUndefined();
  });

  test("the font preset picks a stack; an explicit family wins", () => {
    expect(markdownStyleVariables({ font: { preset: "serif" } })["--cmux-md-font-family"]).toContain("serif");
    expect(markdownStyleVariables({ font: { preset: "mono" } })["--cmux-md-font-family"]).toBe(
      "var(--cmux-md-code-font-family)",
    );
    expect(markdownStyleVariables({ font: { preset: "system" } })["--cmux-md-font-family"]).toBeUndefined();
    expect(markdownStyleVariables({ font: { preset: "serif", family: "Charter" } })["--cmux-md-font-family"]).toBe(
      "Charter",
    );
  });

  test("paragraph spacing as a number is in em; line height and code size pass through", () => {
    const vars = markdownStyleVariables({
      spacing: { paragraph: 1.5 },
      font: { lineHeight: 1.8 },
      code: { blockSize: 13 },
    });
    expect(vars["--cmux-md-paragraph-spacing"]).toBe("1.5em");
    expect(vars["--cmux-md-line-height"]).toBe("1.8");
    expect(vars["--cmux-md-code-block-size"]).toBe("13px");
  });

  test("tables and theme are page attributes, invalid values fall back", () => {
    expect(markdownBehavior({ tables: "wrap", theme: "dark" })).toMatchObject({ tables: "wrap", theme: "dark" });
    expect(markdownBehavior({ tables: "nope", theme: 3 })).toMatchObject({ tables: "scroll", theme: "app" });
    const root = { dataset: {} as Record<string, string> };
    const styles = new Map<string, { id: string; textContent: string }>();
    const doc = {
      documentElement: root,
      head: { append() {} },
      getElementById: (id: string) => styles.get(id) ?? null,
      createElement: () => ({ id: "", textContent: "" }),
    } as unknown as Document;
    applyMarkdownLook({ tables: "wrap", theme: "light" }, "", doc);
    expect(root.dataset).toMatchObject({ cmuxMdTables: "wrap", cmuxMdTheme: "light" });
  });

  test("the popover shows each value, clamped, else the default", () => {
    expect(markdownReadingValues(undefined)).toEqual({
      width: 72,
      fullWidth: false,
      fontSize: 16,
      fontPreset: "system",
      lineHeight: 1.6,
      paragraph: 1,
      codeScale: 0.875,
      tables: "scroll",
      theme: "app",
    });
    const values = markdownReadingValues({ layout: { width: 5000 }, font: { size: "18px", lineHeight: "2" } });
    expect(values.width).toBe(MARKDOWN_READING.width.max);
    expect(values.fontSize).toBe(18);
    expect(values.lineHeight).toBe(2);
  });
});

describe("text width (user 2026-10-19: super wide for a big monitor, but not full width)", () => {
  test("the range reaches an ultrawide monitor; full width is its own key, not the top of it", () => {
    expect(MARKDOWN_READING.width.min).toBe(30);
    expect(MARKDOWN_READING.width.max).toBe(1000);
    expect(MARKDOWN_READING.width.default).toBe(72);
    // 1000ch of a 16px body is about 8,800 CSS pixels: wider than a 5K or 32:9 screen.
    expect(markdownStyleVariables({ layout: { width: 1000 } })["--cmux-md-content-width"]).toBe("1000ch");
    expect(markdownStyleVariables({ layout: { width: 1000 } })["--cmux-md-content-width"]).not.toBe("none");
  });

  test("an out-of-range width takes the nearest end, rounded; it never turns into full width", () => {
    expect(clampWidth(5000)).toBe(1000);
    expect(clampWidth(4)).toBe(30);
    expect(clampWidth(120.4)).toBe(120);
    expect(markdownStyleVariables({ layout: { width: 2400 } })["--cmux-md-content-width"]).toBe("1000ch");
    expect(markdownStyleVariables({ layout: { width: 10 } })["--cmux-md-content-width"]).toBe("30ch");
    expect(markdownReadingValues({ layout: { width: 5000 } })).toMatchObject({ width: 1000, fullWidth: false });
    expect(markdownReadingValues({ layout: { width: 250.6 } }).width).toBe(251);
  });

  test("typed widths: characters, points or pixels, and simple arithmetic", () => {
    const ch = 8;
    expect(parseWidthInput("120", ch)).toBe(120);
    expect(parseWidthInput(" 120ch ", ch)).toBe(120);
    expect(parseWidthInput("1600pt", ch)).toBe(200);
    expect(parseWidthInput("1600 px", ch)).toBe(200);
    expect(parseWidthInput("72*2", ch)).toBe(144);
    expect(parseWidthInput("72 × 2", ch)).toBe(144);
    expect(parseWidthInput("(100 + 60) / 2", ch)).toBe(80);
    expect(parseWidthInput("1200pt + 10ch", ch)).toBe(160);
    expect(parseWidthInput("90,5", ch)).toBe(90.5);
    expect(parseWidthInput("1,600pt", ch)).toBe(200);
    for (const bad of ["", "wide", "12;", "1/0", "(1+2", "1 2", "100em", "alert(1)"])
      expect(parseWidthInput(bad, ch)).toBeNull();
  });

  test("presets: each a width, full width its own; anything else is custom", () => {
    const widths = MARKDOWN_WIDTH_PRESETS.flatMap((preset) => ("width" in preset ? [preset.width] : []));
    expect(widths).toEqual([...widths].sort((a, b) => a - b));
    for (const width of widths) expect(clampWidth(width)).toBe(width);
    expect(markdownWidthPreset({ width: 72, fullWidth: false })).toBe("comfortable");
    expect(markdownWidthPreset({ width: 300, fullWidth: false })).toBe("ultraWide");
    expect(markdownWidthPreset({ width: 72, fullWidth: true })).toBe("fullWidth");
    expect(markdownWidthPreset({ width: 640, fullWidth: false })).toBe("custom");
  });

  test("a wide width persists through the one write path and survives a stale look event", () => {
    const calls: Array<{ op: string; params: unknown }> = [];
    const client = {
      call: async (op: string, params: unknown) => {
        calls.push({ op, params });
        return null;
      },
    } as unknown as PageClient;
    const store = new MarkdownStore(client, () => () => {});
    store.setPreference("markdown.layout.fullWidth", false);
    store.setPreference("markdown.layout.width", 640);
    store.lookChanged({ settings: { layout: { width: 72, fullWidth: true } } } as never);
    expect(markdownReadingValues(store.getState().look.settings)).toMatchObject({ width: 640, fullWidth: false });
    expect(markdownStyleVariables(store.getState().look.settings)["--cmux-md-content-width"]).toBe("640ch");
    store.flushPreferences();
    expect(calls.map((call) => call.params)).toEqual([
      { key: "markdown.layout.fullWidth", value: false },
      { key: "markdown.layout.width", value: 640 },
    ]);
  });
});

describe("code size (user 2026-10-19: code blocks look too big)", () => {
  test("code is a share of the body text, a little smaller, by default", () => {
    const scale = Number(MARKDOWN_STYLE_DEFAULTS["--cmux-md-code-scale"]);
    expect(scale).toBeGreaterThanOrEqual(0.85);
    expect(scale).toBeLessThanOrEqual(0.9);
    expect(scale).toBe(MARKDOWN_READING.codeScale.default);
    // Relative to the body size, so a smaller body never leaves code bigger than the text.
    expect(MARKDOWN_STYLE_DEFAULTS["--cmux-md-code-block-size"]).toContain("var(--cmux-md-font-size)");
    expect(MARKDOWN_STYLE_DEFAULTS["--cmux-md-code-inline-size"]).toContain("var(--cmux-md-code-scale)");
  });

  test("markdown.code.scale sets the share, clamped; a fixed blockSize still wins for blocks", () => {
    expect(markdownStyleVariables({ code: { scale: 0.8 } })["--cmux-md-code-scale"]).toBe("0.8");
    expect(markdownStyleVariables({ code: { scale: 4 } })["--cmux-md-code-scale"]).toBe("1.25");
    expect(markdownStyleVariables({ code: { scale: "big" } })["--cmux-md-code-scale"]).toBeUndefined();
    expect(markdownStyleVariables({ code: { scale: 0.8, blockSize: 13 } })["--cmux-md-code-block-size"]).toBe("13px");
    expect(markdownReadingValues({ code: { scale: 0.3 } }).codeScale).toBe(0.6);
  });
});

describe("reading settings writes", () => {
  test("withMarkdownSetting sets a nested key and null removes it, without mutating", () => {
    const section = { layout: { padding: 20 } };
    const next = withMarkdownSetting(section, "layout.width", 80);
    expect(next).toEqual({ layout: { padding: 20, width: 80 } });
    expect(section).toEqual({ layout: { padding: 20 } });
    expect(withMarkdownSetting(next, "layout.width", null)).toEqual({ layout: { padding: 20 } });
  });

  test("a drag shows every step at once and writes the last one once; a look event keeps it", () => {
    const calls: Array<{ op: string; params: unknown }> = [];
    const client = {
      call: async (op: string, params: unknown) => {
        calls.push({ op, params });
        return null;
      },
    } as unknown as PageClient;
    const timers: Array<{ run: () => void; cancelled: boolean }> = [];
    const schedule: Schedule = (run) => {
      const timer = { run, cancelled: false };
      timers.push(timer);
      return () => {
        timer.cancelled = true;
      };
    };
    const store = new MarkdownStore(client, schedule);
    for (const width of [74, 76, 78]) store.setPreference("markdown.layout.width", width);
    expect(markdownReadingValues(store.getState().look.settings).width).toBe(78);
    // The host re-sends an older look before the write: the chosen value stays.
    store.lookChanged({ settings: { layout: { width: 72 } } } as never);
    expect(markdownReadingValues(store.getState().look.settings).width).toBe(78);
    for (const timer of timers) if (!timer.cancelled) timer.run();
    const writes = calls.filter((call) => call.op === "cmux.markdown.setPreference");
    expect(writes).toEqual([
      { op: "cmux.markdown.setPreference", params: { key: "markdown.layout.width", value: 78 } },
    ]);
  });

  test("reset writes null for the key; flush sends what is still waiting", () => {
    const calls: unknown[] = [];
    const client = {
      call: async (_op: string, params: unknown) => {
        calls.push(params);
        return null;
      },
    } as unknown as PageClient;
    const store = new MarkdownStore(client, () => () => {});
    store.setPreference("markdown.theme", "dark");
    store.setPreference("markdown.theme", null);
    expect(markdownReadingValues(store.getState().look.settings).theme).toBe("app");
    store.flushPreferences();
    expect(calls).toEqual([{ key: "markdown.theme", value: null }]);
  });

  test("only markdown.* keys", () => {
    const store = new MarkdownStore(null, () => () => {});
    store.setPreference("editor.wordWrap", "on");
    expect(store.getState().look.settings).toBeUndefined();
  });
});
