// Theme-token mapping for the /agent-chat surface: valid host tokens land on
// the documentElement as `--agent-*` CSS custom properties through the shared
// applyAgentTheme seam; absent/invalid tokens leave the document untouched so
// the system-scheme CSS fallback stays in effect.

import { afterEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { AgentSessionTheme } from "../agent-session/shared/types";
import { applyAgentChatTheme, parseAgentChatTheme } from "./theme";

let dom: JSDOM | null = null;
const originalDocument = globalThis.document;
const originalNavigator = globalThis.navigator;

function installDom(): Document {
  dom = new JSDOM("<!doctype html><html><body></body></html>");
  (globalThis as { document?: Document }).document = dom.window.document;
  (globalThis as { navigator?: Navigator }).navigator = dom.window.navigator;
  return dom.window.document;
}

afterEach(() => {
  dom?.window.close();
  dom = null;
  if (originalDocument === undefined) {
    delete (globalThis as { document?: Document }).document;
  } else {
    (globalThis as { document?: Document }).document = originalDocument;
  }
  if (originalNavigator === undefined) {
    delete (globalThis as { navigator?: Navigator }).navigator;
  } else {
    (globalThis as { navigator?: Navigator }).navigator = originalNavigator;
  }
});

function hostTheme(overrides: Partial<AgentSessionTheme> = {}): AgentSessionTheme {
  return {
    isDark: true,
    pageBackground: "rgb(30, 30, 30)",
    surfaceBackground: "rgba(40, 40, 40, 0.72)",
    surfaceElevatedBackground: "rgba(48, 48, 48, 0.84)",
    inputBackground: "rgba(60, 60, 60, 0.6)",
    border: "rgba(127, 127, 127, 0.25)",
    borderStrong: "rgba(127, 127, 127, 0.45)",
    text: "rgb(214, 214, 214)",
    mutedText: "rgba(214, 214, 214, 0.58)",
    softText: "rgba(214, 214, 214, 0.78)",
    accent: "rgb(79, 143, 247)",
    accentSoft: "rgba(79, 143, 247, 0.2)",
    danger: "rgb(255, 141, 126)",
    shadow: "rgba(0, 0, 0, 0.2)",
    ...overrides,
  };
}

describe("parseAgentChatTheme", () => {
  test("accepts the full host token set", () => {
    expect(parseAgentChatTheme(hostTheme())).toEqual(hostTheme());
  });

  test("rejects non-objects and missing/mistyped tokens", () => {
    expect(parseAgentChatTheme(undefined)).toBeNull();
    expect(parseAgentChatTheme(null)).toBeNull();
    expect(parseAgentChatTheme("dark")).toBeNull();
    expect(parseAgentChatTheme({ ...hostTheme(), isDark: "yes" })).toBeNull();
    expect(parseAgentChatTheme({ ...hostTheme(), accent: 42 })).toBeNull();
    expect(parseAgentChatTheme({ ...hostTheme(), text: "" })).toBeNull();
    const partial: Record<string, unknown> = { ...hostTheme() };
    delete partial.pageBackground;
    expect(parseAgentChatTheme(partial)).toBeNull();
  });
});

describe("applyAgentChatTheme", () => {
  test("maps tokens onto the --agent-* CSS custom properties", () => {
    const document = installDom();
    const applied = applyAgentChatTheme(hostTheme());
    expect(applied).toBe(true);
    const style = document.documentElement.style;
    expect(style.getPropertyValue("--agent-page-bg")).toBe("rgb(30, 30, 30)");
    expect(style.getPropertyValue("--agent-surface")).toBe("rgba(40, 40, 40, 0.72)");
    expect(style.getPropertyValue("--agent-surface-elevated")).toBe("rgba(48, 48, 48, 0.84)");
    expect(style.getPropertyValue("--agent-input-bg")).toBe("rgba(60, 60, 60, 0.6)");
    expect(style.getPropertyValue("--agent-border")).toBe("rgba(127, 127, 127, 0.25)");
    expect(style.getPropertyValue("--agent-border-strong")).toBe("rgba(127, 127, 127, 0.45)");
    expect(style.getPropertyValue("--agent-text")).toBe("rgb(214, 214, 214)");
    expect(style.getPropertyValue("--agent-muted")).toBe("rgba(214, 214, 214, 0.58)");
    expect(style.getPropertyValue("--agent-soft")).toBe("rgba(214, 214, 214, 0.78)");
    expect(style.getPropertyValue("--agent-accent")).toBe("rgb(79, 143, 247)");
    expect(style.getPropertyValue("--agent-accent-soft")).toBe("rgba(79, 143, 247, 0.2)");
    expect(style.getPropertyValue("--agent-danger")).toBe("rgb(255, 141, 126)");
    expect(style.getPropertyValue("--agent-shadow")).toBe("rgba(0, 0, 0, 0.2)");
    expect(document.documentElement.dataset.theme).toBe("dark");
    expect(style.colorScheme).toBe("dark");
  });

  test("marks light themes for the light-variant companion tokens", () => {
    const document = installDom();
    expect(applyAgentChatTheme(hostTheme({ isDark: false }))).toBe(true);
    expect(document.documentElement.dataset.theme).toBe("light");
    expect(document.documentElement.style.colorScheme).toBe("light");
  });

  test("leaves the document untouched when tokens are absent or invalid", () => {
    const document = installDom();
    expect(applyAgentChatTheme(undefined)).toBe(false);
    expect(applyAgentChatTheme({ isDark: true })).toBe(false);
    expect(document.documentElement.dataset.theme).toBeUndefined();
    expect(document.documentElement.style.getPropertyValue("--agent-page-bg")).toBe("");
  });
});
