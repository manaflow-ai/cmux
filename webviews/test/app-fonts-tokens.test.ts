// l10n-allow-file: test fixture chat text, not shipped UI.
// Settings > Appearance > Fonts (appearance.fonts.*): the host sends the text face, the code face and
// the chat size with every theme (WebTheme.swift: `--cmux-font-ui`, `--cmux-font-code`,
// `--cmux-font-chat-size` on the root, `initial` when unset, and `codeFontFamily`). The chat, the
// composer, desktop pages, diffs, markdown and the editor read them; unset, each keeps its own look.
import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { layoutConversation, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { applyDiffViewerAppearance, resolveDiffViewerAppearance } from "../src/appearance";
import { EDITOR_DEFAULTS, monacoOptions } from "../src/pages/editor/settings";

type ThemeWindow = Window & { cmuxTheme?: { current?: unknown } };
const SRC = path.resolve(import.meta.dir, "../src");
const sheet = (file: string) => fs.readFileSync(path.join(SRC, file), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html>");
  Object.assign(globalThis, { window, document: window.document });
});

afterEach(() => {
  delete (window as ThemeWindow).cmuxTheme;
  document.documentElement.removeAttribute("style");
});

/** What `window.cmuxTheme.apply` does with a payload: variables on the root, then `cmux-theme`. */
function hostSends(
  variables: Record<string, string>,
  codeFontFamily: string | null,
  terminalFamily: string | null = null,
) {
  const terminal = {
    type: "dark",
    background: "#101018",
    foreground: "#e8e8f0",
    palette: {},
    fontFamily: terminalFamily,
  };
  const payload = { variables, colorScheme: "dark", scrollers: "overlay", terminal, codeFontFamily };
  for (const [name, value] of Object.entries(variables)) document.documentElement.style.setProperty(name, value);
  (window as ThemeWindow).cmuxTheme = { current: payload };
  window.dispatchEvent(new window.CustomEvent("cmux-theme", { detail: payload }));
}

const UNSET = { "--cmux-font-ui": "initial", "--cmux-font-code": "initial", "--cmux-font-chat-size": "initial" };
const CHOSEN = {
  "--cmux-font-ui": 'ui-serif, "New York", Georgia, serif',
  "--cmux-font-code": '"Courier New", ui-monospace, "SF Mono", Menlo, monospace',
  "--cmux-font-chat-size": "18px",
};

const reply: AcpmuxRow = {
  id: "a1",
  version: 1,
  at: 0,
  kind: "assistant",
  text: "Each attempt now waits twice as long as the one before. ".repeat(12),
};
const chatHeight = () => layoutConversation([reply], 640).totalHeight;
const editorFamily = () =>
  monacoOptions(EDITOR_DEFAULTS, undefined, { readOnly: false, large: false, ariaLabel: "code" }).fontFamily as string;
const diffCodeFamily = () => document.documentElement.style.getPropertyValue("--cmux-diff-code-font-family").trim();

describe("app fonts reach the pages", () => {
  test("the chat lays its text out at the chosen size, and at 14px when unset", () => {
    hostSends(UNSET, null);
    const unset = chatHeight();
    hostSends(CHOSEN, "Courier New");
    const larger = chatHeight();
    expect(larger).toBeGreaterThan(unset);
    hostSends(UNSET, null);
    expect(chatHeight()).toBe(unset);
  });

  test("the code editor and diffs draw code in the chosen face, else the terminal's", () => {
    hostSends(CHOSEN, "Courier New", "Fira Code");
    expect(editorFamily().startsWith('"Courier New",')).toBe(true);
    applyDiffViewerAppearance(resolveDiffViewerAppearance(undefined));
    expect(diffCodeFamily().startsWith('"Courier New",')).toBe(true);

    hostSends(UNSET, "Fira Code", "Fira Code");
    expect(editorFamily().startsWith('"Fira Code",')).toBe(true);
  });

  test("every surface's face and the chat size read the host's variables, with today's as fallback", () => {
    const reads: [string, RegExp][] = [
      ["agent-session/acpmux/conversation/conversation.css", /--cv-font-size:\s*var\(--cmux-font-chat-size,\s*14px\)/],
      [
        "agent-session/acpmux/conversation/conversation.css",
        /--cv-line-height:\s*calc\(var\(--cv-font-size\)\s*\*\s*1\.625\)/,
      ],
      ["agent-session/acpmux/conversation/conversation.css", /--cv-font:\s*var\(--cmux-font-ui,\s*system-ui\)/],
      ["agent-session/acpmux/conversation/conversation.css", /--cv-mono:\s*var\(--cmux-font-code,\s*ui-monospace/],
      ["agent-session/acpmux/styles.css", /font:\s*13px var\(--cmux-font-ui,\s*-apple-system/],
      ["pages/shared/desktop.css", /font-family:\s*var\(--cmux-font-ui,\s*-apple-system/],
      ["styles.css", /--cmux-diff-ui-font-family:\s*var\(--cmux-font-ui,\s*system-ui/],
      ["styles.css", /--cmux-diff-code-font-family:\s*var\(--cmux-font-code,\s*ui-monospace/],
      ["pages/markdown/styles.css", /--cmux-md-font-family:\s*var\(--cmux-font-ui,/],
      ["ui/ui.css", /--ui-font:\s*var\(--cmux-font-ui,/],
    ];
    const missing = reads
      .filter(([file, pattern]) => !pattern.test(sheet(file)))
      .map(([file, pattern]) => `${file} ${pattern}`);
    expect(missing).toEqual([]);
  });
});
