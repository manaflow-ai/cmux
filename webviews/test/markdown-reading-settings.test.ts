// The markdown viewer's Reading Settings (user 2026-10-19: "make it easier to adjust tons of
// settings in markdown viewer like max width"): each popover row is one `markdown.*` key, its CSS
// variable follows at once, a slider drag writes the settings file once, and Reset removes the keys.
import { describe, expect, test } from "bun:test";
import {
  MARKDOWN_READING,
  applyMarkdownLook,
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
      codeSize: 14,
      tables: "scroll",
      theme: "app",
    });
    const values = markdownReadingValues({ layout: { width: 999 }, font: { size: "18px", lineHeight: "2" } });
    expect(values.width).toBe(MARKDOWN_READING.width.max);
    expect(values.fontSize).toBe(18);
    expect(values.lineHeight).toBe(2);
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
