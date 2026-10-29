// The native Static status indicators look (or Reduce Motion) reaches the agent pane through its
// theme (cx-sya4n): applyAgentTheme sets `data-status-indicators` on the root, which the
// stylesheets stop their loops under (static-status-loops.test.ts checks the rules).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const scope = globalThis as Record<string, unknown>;
const saved = ["window", "document"].map((key) => [key, key in scope, scope[key]] as const);

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><html><body></body></html>");
  Object.assign(scope, { window, document: window.document });
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
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

test("the theme's status indicators look reaches the root, and a theme without it clears it", async () => {
  const { applyAgentTheme } = await import("../src/agent-session/shared/theme");
  const root = document.documentElement;
  applyAgentTheme({ ...theme, statusIndicators: "static" } as Parameters<typeof applyAgentTheme>[0]);
  expect(root.dataset.statusIndicators).toBe("static");
  applyAgentTheme({ ...theme, statusIndicators: "animated" } as Parameters<typeof applyAgentTheme>[0]);
  expect(root.dataset.statusIndicators).toBe("animated");
  applyAgentTheme(theme as Parameters<typeof applyAgentTheme>[0]);
  expect(root.dataset.statusIndicators).toBeUndefined();
});

test("focus ring setting gates transcript response outlines and defaults off", async () => {
  const { applyAgentTheme } = await import("../src/agent-session/shared/theme");
  const root = document.documentElement;
  applyAgentTheme({ ...theme, focusRingEnabled: true } as Parameters<typeof applyAgentTheme>[0]);
  expect(root.dataset.focusRingEnabled).toBe("true");
  applyAgentTheme({ ...theme, focusRingEnabled: false } as Parameters<typeof applyAgentTheme>[0]);
  expect(root.dataset.focusRingEnabled).toBeUndefined();
  applyAgentTheme(theme as Parameters<typeof applyAgentTheme>[0]);
  expect(root.dataset.focusRingEnabled).toBeUndefined();
});
