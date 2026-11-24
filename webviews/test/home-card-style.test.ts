// appearance.homeCardStyle reaches Home and the New Tab page through the pane's theme (AgentPaneTheme.swift
// `homeCardStyle`): applyAgentTheme sets `data-home-cards` on the root, which newtab/screen.css's HOME-CARDS rules draw
// under. `standard` (the default) leaves today's cards, so it sets nothing.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const saved = ["window", "document"].map((key) => [key, key in scope, scope[key]] as const);

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><html><body></body></html>");
  Object.assign(scope, { window, document: window.document });
});
afterAll(async () => {
  await teardownDom(saved, { scope });
});

const theme = {
  isDark: false,
  pageBackground: "#fff",
  surfaceBackground: "#fff",
  surfaceElevatedBackground: "#fff",
  inputBackground: "#fff",
  border: "#ddd",
  borderStrong: "#ccc",
  text: "#000",
  mutedText: "#666",
  softText: "#999",
  accent: "#000",
  accentSoft: "#eee",
  danger: "#c00",
  shadow: "#0003",
};

test("each card style reaches the root; standard, a theme without it and an unknown value clear it", async () => {
  const { applyAgentTheme } = await import("../src/agent-session/shared/theme");
  type Theme = Parameters<typeof applyAgentTheme>[0];
  const root = document.documentElement;
  for (const style of ["flat", "raised", "glass"] as const) {
    applyAgentTheme({ ...theme, homeCardStyle: style } as Theme);
    expect(root.dataset.homeCards).toBe(style);
  }
  applyAgentTheme({ ...theme, homeCardStyle: "standard" } as Theme);
  expect(root.dataset.homeCards).toBeUndefined();
  applyAgentTheme({ ...theme, homeCardStyle: "glass" } as Theme);
  applyAgentTheme(theme as Theme);
  expect(root.dataset.homeCards).toBeUndefined();
  applyAgentTheme({ ...theme, homeCardStyle: "wobbly" } as unknown as Theme);
  expect(root.dataset.homeCards).toBeUndefined();
});

test("screen.css draws every style on the chat cards, the stage cards and the Home lists, never the list rows", () => {
  const css = readFileSync(path.join(import.meta.dir, "../src/agent-session/acpmux/newtab/screen.css"), "utf8");
  const cards = ':is(.nt-cards:not([data-variant="list"]) .nt-card, .nt-stage-card, .acpmux-home-list)';
  for (const style of ["flat", "raised", "glass"]) {
    expect(css).toContain(`:root[data-home-cards="${style}"] ${cards} {`);
  }
  // flat has no edge and no shadow; raised a hairline and a shadow; glass a backdrop and a rim.
  const rule = (style: string) => {
    const start = css.indexOf(`:root[data-home-cards="${style}"] ${cards} {`);
    return css.slice(start, css.indexOf("}", start));
  };
  expect(rule("flat")).toContain("box-shadow: none");
  expect(rule("raised")).toContain("var(--cmux-hairline");
  expect(rule("raised")).toContain("--elevation-2");
  expect(rule("glass")).toContain("backdrop-filter");
  expect(rule("glass")).toContain("--glass-material-rim");
  // No rule names `standard`: the default is today's cards, untouched.
  expect(css).not.toContain('data-home-cards="standard"');
});
