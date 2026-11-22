import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { pageError, type PageClient } from "../shared/pageClient";
import { MARKDOWN_LOOK, type MarkdownLook } from "./host";
import {
  MARKDOWN_STYLE_DEFAULTS,
  bindMarkdownLook,
  markdownBehavior,
  markdownCodeTheme,
  markdownStyleVariables,
} from "./settings";
import { MarkdownStore } from "./store";

const css = fs.readFileSync(path.join(import.meta.dir, "styles.css"), "utf8");

describe("--cmux-md-* variables", () => {
  const defaultsBlock = css.slice(css.indexOf(":where(:root) {"), css.indexOf("}", css.indexOf(":where(:root) {")));
  const declared = new Map(
    [...defaultsBlock.matchAll(/(--cmux-md-[a-z0-9-]+):\s*([^;]+);/g)].map((m) => [m[1], m[2].trim()]),
  );
  const used = new Set([...css.matchAll(/var\((--cmux-md-[a-z0-9-]+)/g)].map((m) => m[1]));

  test("every variable the stylesheet uses has a default", () => {
    expect([...used].filter((name) => !declared.has(name))).toEqual([]);
  });

  test("the stylesheet defaults are the typed table, one for one", () => {
    expect(Object.fromEntries(declared)).toEqual({ ...MARKDOWN_STYLE_DEFAULTS });
  });

  test("every typed variable is used by the stylesheet", () => {
    expect(Object.keys(MARKDOWN_STYLE_DEFAULTS).filter((name) => !used.has(name))).toEqual([]);
  });

  test("no hard-coded colors or font sizes outside the defaults", () => {
    const rules = css.slice(css.indexOf("}", css.indexOf(":where(:root) {")) + 1);
    const offending = rules
      .split("\n")
      .filter((line) => /^\s*(color|background|font-size|font-family|border-color|caret-color)\s*:/.test(line))
      .filter((line) => !/var\(|transparent|inherit/.test(line));
    expect(offending).toEqual([]);
  });
});

describe("settings map onto variables", () => {
  test("reading defaults are comfortable: 16px body, 1.6 line height, 72ch column", () => {
    expect(MARKDOWN_STYLE_DEFAULTS["--cmux-md-font-size"]).toBe("16px");
    expect(MARKDOWN_STYLE_DEFAULTS["--cmux-md-line-height"]).toBe("1.6");
    expect(MARKDOWN_STYLE_DEFAULTS["--cmux-md-content-width"]).toBe("72ch");
  });

  test("numbers become lengths, pairs become light-dark, a scale sizes the headings", () => {
    expect(
      markdownStyleVariables({
        font: { family: "Georgia, serif", size: 17, weight: 450, lineHeight: 1.7 },
        headings: { scale: 1.2, sizes: [2.5] },
        code: { family: "Berkeley Mono", inlineSize: 0.9, blockSize: 13 },
        layout: { maxWidth: "80ch", padding: 24 },
        spacing: { paragraph: "1.2em", list: 4 },
        colors: { link: { light: "#00f", dark: "#8af" }, selection: "rgb(0 0 255 / 0.2)", tableBorder: "#ccc" },
      }),
    ).toEqual({
      "--cmux-md-font-family": "Georgia, serif",
      "--cmux-md-font-size": "17px",
      "--cmux-md-font-weight": "450",
      "--cmux-md-line-height": "1.7",
      "--cmux-md-h1-size": "2.5em",
      "--cmux-md-h2-size": "1.728em",
      "--cmux-md-h3-size": "1.44em",
      "--cmux-md-h4-size": "1.2em",
      "--cmux-md-h5-size": "1em",
      "--cmux-md-h6-size": "0.833em",
      "--cmux-md-code-font-family": "Berkeley Mono",
      "--cmux-md-code-inline-size": "0.9em",
      "--cmux-md-code-block-size": "13px",
      "--cmux-md-content-width": "80ch",
      "--cmux-md-page-padding": "24px",
      "--cmux-md-paragraph-spacing": "1.2em",
      "--cmux-md-list-spacing": "4px",
      "--cmux-md-link-color": "light-dark(#00f, #8af)",
      "--cmux-md-selection-color": "rgb(0 0 255 / 0.2)",
      "--cmux-md-table-border": "1px solid #ccc",
    });
  });

  test("values that could break out of the declaration are dropped", () => {
    expect(
      markdownStyleVariables({ font: { family: "x; } body { display: none", size: -1 }, colors: { link: "</style>" } }),
    ).toEqual({});
  });

  test("mode, toolbar and code theme", () => {
    expect(markdownBehavior(undefined)).toEqual({ defaultMode: "rich", toolbar: true });
    expect(markdownBehavior({ defaultMode: "source", toolbar: false })).toEqual({
      defaultMode: "source",
      toolbar: false,
    });
    expect(markdownCodeTheme(undefined)).toEqual({ light: "terminal", dark: "terminal" });
    expect(markdownCodeTheme({ code: { theme: { light: "github-light", dark: "github-dark" } } })).toEqual({
      light: "github-light",
      dark: "github-dark",
    });
  });
});

describe("a settings change updates the page without a reload", () => {
  let dom: JSDOM;
  beforeAll(() => {
    dom = new JSDOM('<!doctype html><html><head><link rel="stylesheet" href="page.css"></head><body></body></html>', {
      url: "https://cmux.markdown/markdown-page.html",
    });
  });
  afterAll(() => dom.window.close());

  test("settings, theme.css and the toolbar flag apply in place, and the default mode applies at open", async () => {
    let push: ((look: MarkdownLook, seq: number) => void) | null = null;
    const client: PageClient = {
      async call<R>(op: string): Promise<R> {
        if (op === "cmux.markdown.config") {
          return {
            path: "/w/a.md",
            text: "# A\n",
            hash: "h",
            settings: { font: { size: 17 }, defaultMode: "source" },
            themeCSS: ".md-prose { letter-spacing: 0.01em; }",
          } as R;
        }
        throw pageError("cmux.protocol.unknown_op", op);
      },
      async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void) {
        if (stream === MARKDOWN_LOOK) push = onEvent as never;
        return () => {};
      },
      handle: () => () => {},
    };
    const store = new MarkdownStore(client);
    const doc = dom.window.document;
    const codeThemes: unknown[] = [];
    bindMarkdownLook(store, { codeTheme: (names) => codeThemes.push(names) }, doc);
    await store.start();
    const settingsStyle = () => doc.getElementById("cmux-md-settings")?.textContent ?? "";
    const themeStyle = () => doc.getElementById("cmux-md-theme")?.textContent ?? "";
    expect(store.getState().mode).toBe("source");
    expect(settingsStyle()).toContain("--cmux-md-font-size: 17px;");
    expect(themeStyle()).toBe(".md-prose { letter-spacing: 0.01em; }");
    // The user styles come after the page stylesheet: settings, then theme.css.
    const order = [...doc.head.children].map((node) => node.id || node.tagName.toLowerCase());
    expect(order).toEqual(["link", "cmux-md-settings", "cmux-md-theme"]);

    const location = dom.window.location.href;
    push!({ settings: { font: { size: 20 }, toolbar: false, code: { theme: "github-dark" } } }, 1);
    expect(settingsStyle()).toContain("--cmux-md-font-size: 20px;");
    expect(themeStyle()).toBe(".md-prose { letter-spacing: 0.01em; }");
    expect(doc.documentElement.dataset.cmuxMdToolbar).toBe("false");
    expect(codeThemes).toEqual([{ light: "github-dark", dark: "github-dark" }]);
    // A settings change does not flip the mode the user is in.
    expect(store.getState().mode).toBe("source");

    push!({ themeCSS: "" }, 2);
    expect(themeStyle()).toBe("");
    expect(settingsStyle()).toContain("--cmux-md-font-size: 20px;");
    expect(dom.window.location.href).toBe(location);
  });
});
