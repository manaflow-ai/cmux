import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "ShadowRoot",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "CSSStyleSheet",
  "DocumentFragment",
  "SVGElement",
  "HTMLTemplateElement",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    ShadowRoot: dom.window.ShadowRoot,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    CSSStyleSheet: dom.window.CSSStyleSheet,
    DocumentFragment: dom.window.DocumentFragment,
    SVGElement: dom.window.SVGElement,
    HTMLTemplateElement: dom.window.HTMLTemplateElement,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  for (const popup of dom.window.document.querySelectorAll(".acpmux-quick-menu")) popup.remove();
});

afterAll(async () => {
  // A checkbox indicator's last update lands a task after the final test: let it run on this window.
  await settle();
  await teardownDom(saved, { window: dom.window, scope });
});

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

// Leo 2026-10-26: "show all harnesses, all models (pi, opencode, prime intellect, etc…)". The picker
// dropped every catalog harness this machine does not have, so Pi, OpenCode, Gemini and the rest
// never showed. Each now has its rail tab after the installed ones, its catalog models listed but
// not pickable, and an Install… row.
const claude = { id: "claude", name: "Claude Code", models: [{ id: "opus", name: "Opus 5.5" }], pickable: true };
const gemini = {
  id: "gemini",
  name: "Gemini CLI",
  models: [{ id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro" }],
  pickable: false,
  notInstalled: true as const,
};
const pi = { id: "pi", name: "Pi", models: [], pickable: false, notInstalled: true as const };

describe("harnesses this machine does not have", () => {
  test("the picker's face stays on an installed harness", async () => {
    const { pickerFaceHarness } = await import("../src/agent-session/acpmux/modelPickerModel");
    expect(pickerFaceHarness([gemini, pi, claude])).toBe("claude");
    expect(pickerFaceHarness([gemini, pi])).toBeUndefined();
  });

  test("the composer's entries flag a catalog harness that is not installed", async () => {
    const { composerPickerEntries } = await import("../src/agent-session/acpmux/composerPickerEntries");
    const harness = (id: string, installed: boolean) => ({
      id,
      name: id,
      brand: id,
      acpmuxHarness: installed ? id : null,
      installed,
      pickable: true,
      models: [],
    });
    const entries = composerPickerEntries({ catalog: [], summary: undefined } as never, {
      harnesses: [harness("claude", true), harness("pi", false)],
      provisional: false,
    });
    expect(entries.map((entry) => [entry.id, entry.pickable, entry.notInstalled])).toEqual([
      ["claude", true, undefined],
      ["pi", false, true],
    ]);
  });

  test("the full picker lists uninstalled catalog models as disabled beside Install…", async () => {
    const { createRoot } = await import("react-dom/client");
    const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
    const picked: string[] = [];
    let added = 0;
    root = createRoot(host);
    await act(async () =>
      root!.render(
        <ModelPicker
          catalog={[gemini, claude, pi]}
          harness="claude"
          model="opus"
          label="Opus 5.5"
          efforts={[]}
          recents={[]}
          onLand={(id) => picked.push(id)}
          onCombo={(combo) => picked.push(combo.model)}
          onHarness={(id) => picked.push(id)}
          onEffort={() => {}}
          onAddAgent={() => added++}
        />,
      ),
    );
    await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-picker-button")!.click());
    await settle();
    const doc = dom.window.document;
    const geminiTab = [...doc.querySelectorAll<HTMLButtonElement>(".acpmux-mp-harness")].find(
      (tab) => tab.textContent?.trim() === "Gemini CLI",
    )!;
    expect(geminiTab).not.toBeUndefined();
    await act(async () => geminiTab.click());
    await settle();
    const row = [...doc.querySelectorAll<HTMLButtonElement>('.acpmux-mp-models [role="option"]')].find((item) =>
      item.textContent?.includes("Gemini 3.1 Pro"),
    )!;
    expect(row).not.toBeUndefined();
    expect(row.disabled).toBe(true);
    expect(row.getAttribute("aria-disabled")).toBe("true");
    await act(async () => row.click());
    expect(picked).toEqual([]);
    const install = [...doc.querySelectorAll<HTMLButtonElement>(".acpmux-mp-models button")].find(
      (item) => item.textContent?.trim() === "Install…",
    )!;
    expect(install).not.toBeUndefined();
    // Install leads the list: it comes before every inert catalog model row.
    expect(install.compareDocumentPosition(row) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    await act(async () => install.click());
    expect(added).toBe(1);
  });

  test("the compact menu lists them with their models and an Install… row", async () => {
    const { createRoot } = await import("react-dom/client");
    const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
    const picked: string[] = [];
    let added = 0;
    root = createRoot(host);
    await act(async () =>
      root!.render(
        <ModelPicker
          catalog={[gemini, claude, pi]}
          harness="claude"
          model="opus"
          label="Opus 5.5"
          efforts={[]}
          recents={[]}
          onLand={(id) => picked.push(id)}
          onCombo={(combo) => picked.push(combo.model)}
          onHarness={(id) => picked.push(id)}
          onEffort={() => {}}
          onAddAgent={() => added++}
          quick={{}}
        />,
      ),
    );
    await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
    await settle();
    const doc = dom.window.document;
    const tabs = [...doc.querySelectorAll<HTMLElement>(".acpmux-cols-tab")].map((tab) => tab.title);
    // Starred always first, installed next, then the rest in catalog order.
    expect(tabs).toEqual([
      "Starred",
      "Claude Code",
      "Gemini CLI · Not installed",
      "Pi · Not installed",
      "Add harness…",
    ]);
    const geminiTab = doc.querySelector<HTMLElement>('.acpmux-cols-tab[role="tab"][aria-label="Gemini CLI"]')!;
    await act(async () => geminiTab.click());
    await settle();
    expect(geminiTab.getAttribute("aria-selected")).toBe("true");
    const menu = doc.querySelector('.acpmux-cols [role="listbox"]')!;
    expect(menu.textContent).toContain("Gemini 3.1 Pro");
    expect(menu.querySelector(".acpmux-cols-note")?.textContent).toBe("Not installed");
    const row = [...menu.querySelectorAll<HTMLElement>('[role="option"]')].find((item) =>
      item.textContent?.includes("Gemini 3.1 Pro"),
    )!;
    expect(row.getAttribute("aria-disabled")).toBe("true");
    await act(async () => row.click());
    expect(picked).toEqual([]);
    const install = [...menu.querySelectorAll<HTMLElement>('[role="button"]')].find(
      (item) => item.textContent === "Install…",
    )!;
    await act(async () => install.click());
    expect(added).toBe(1);
  });
});

// Lucas 2026-11-25: "reconcile everything and sort of package it and organize it". A harness that
// reports only its default (Chief) is a tab that starts it, never "No models yet"; one whose probe
// failed (Gemini CLI with no API key) says Unavailable on its tab.
describe("harnesses that cannot list models", () => {
  test("an unavailable harness says so on its tab", async () => {
    const { createRoot } = await import("react-dom/client");
    const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
    const geminiCli = {
      id: "gemini",
      name: "Gemini CLI",
      models: [{ id: "gemini-3.8-flash", name: "3.8 Flash" }],
      pickable: true,
      unavailable: "Gemini API key is missing or not configured.",
    };
    root = createRoot(host);
    await act(async () =>
      root!.render(
        <ModelPicker
          catalog={[claude, geminiCli]}
          harness="claude"
          model="opus"
          label="Opus 5.5"
          efforts={[]}
          recents={[]}
          onLand={() => {}}
          onCombo={() => {}}
          onHarness={() => {}}
          onEffort={() => {}}
          quick={{}}
        />,
      ),
    );
    await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
    await settle();
    const titles = [...dom.window.document.querySelectorAll<HTMLElement>('.acpmux-cols-tab[role="tab"]')].map(
      (tab) => tab.title,
    );
    expect(titles).toContain("Gemini CLI · Unavailable");
  });

  // Lucas 2026-11-25: "we should also remove chief as a harness".
  test("the Chief is no harness of a New Tab's picker; a chat on it keeps it", async () => {
    const { composerPickerEntries } = await import("../src/agent-session/acpmux/composerPickerEntries");
    const picker = {
      provisional: false,
      harnesses: [
        { id: "claude", name: "Claude Code", acpmuxHarness: "claude", installed: true, pickable: true, models: [] },
        {
          id: "chief",
          name: "Chief",
          family: "chief",
          acpmuxHarness: "chief",
          installed: true,
          pickable: true,
          models: [],
        },
      ],
    };
    const ids = (harness: string) =>
      composerPickerEntries(
        { catalog: [], summary: { sessionId: "", harness, turnCount: 0 } } as never,
        picker as never,
      ).map((entry) => entry.id);
    expect(ids("claude")).toEqual(["claude"]);
    expect(ids("chief")).toEqual(["claude", "chief"]);
  });
});

// Lucas 2026-11-25: "inside of Gemini, I can see there's Claude opus 5.5 and Claude Sonnet 5.5".
// Antigravity is a route of the Gemini tab and lists only Gemini models there; and a chat on the
// Chief keeps the columns menu ("it takes you back to the other design").
describe("every tab lists only its own models", () => {
  test("the Gemini tab's Antigravity route lists no Claude or GPT-OSS model, also in search", async () => {
    const { createRoot } = await import("react-dom/client");
    const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
    const antigravity = {
      id: "antigravity",
      name: "Antigravity",
      mark: "antigravity",
      pickable: true,
      models: [
        { id: "gemini-4-neon", name: "Gemini 4 Neon" },
        { id: "gemini-3.8-flash", name: "Gemini 3.8 Flash" },
        { id: "claude-opus-5-5", name: "Claude Opus 5.5" },
        { id: "gpt-oss-120b-medium", name: "GPT-OSS 120B (Medium)" },
      ],
    };
    root = createRoot(host);
    await act(async () =>
      root!.render(
        <ModelPicker
          catalog={[claude, antigravity]}
          harness="antigravity"
          model="gemini-4-neon"
          label="Gemini 4 Neon"
          efforts={[]}
          recents={[]}
          onLand={() => {}}
          onCombo={() => {}}
          onHarness={() => {}}
          onEffort={() => {}}
          quick={{}}
        />,
      ),
    );
    await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
    await settle();
    const doc = dom.window.document;
    const options = () =>
      [...doc.querySelectorAll<HTMLElement>('.acpmux-cols [role="option"]')].map((row) => row.textContent?.trim());
    const gemini = doc.querySelector<HTMLElement>('.acpmux-cols-tab[role="tab"][aria-label="Gemini"]')!;
    await act(async () => gemini.click());
    await settle();
    expect(options()).toEqual(["Gemini 4 Neon", "Gemini 3.8 Flash"]);
    const input = doc.querySelector<HTMLInputElement>(".acpmux-cols input")!;
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
      setter.call(input, "opus");
      input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
    await settle();
    const groups = [...doc.querySelectorAll<HTMLElement>(".acpmux-cols-group")].map((row) => row.textContent?.trim());
    expect(groups.some((name) => name?.startsWith("Gemini"))).toBe(false);
  });

  test("a chat on the Chief keeps the columns menu, and its tab says it picks its own model", async () => {
    const { createRoot } = await import("react-dom/client");
    const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
    const chief = {
      id: "chief",
      name: "Chief",
      family: "chief",
      models: [{ id: "default", name: "default (agent's choice)" }],
      pickable: true,
    };
    root = createRoot(host);
    await act(async () =>
      root!.render(
        <ModelPicker
          catalog={[claude, chief]}
          harness="chief"
          model="default"
          label="Chief"
          efforts={[]}
          recents={[]}
          onLand={() => {}}
          onCombo={() => {}}
          onHarness={() => {}}
          onEffort={() => {}}
          quick={{}}
        />,
      ),
    );
    await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
    await settle();
    const doc = dom.window.document;
    expect(doc.querySelector(".acpmux-cols")).not.toBeNull();
    const tab = doc.querySelector<HTMLElement>('.acpmux-cols-tab[role="tab"][aria-label="Chief"]')!;
    expect(tab.getAttribute("aria-selected")).toBe("true");
    expect(doc.querySelector('.acpmux-cols [role="listbox"]')?.textContent).toContain(
      "Your Chief picks its own model.",
    );
  });
});

// Review (2026-11-25): a harness whose probe has not answered lists only acpmux's "default" row;
// its tab waits ("No models yet"), and a click on it starts nothing.
test("a harness whose models are still loading is no launch tab", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
  const picked: string[] = [];
  const loading = { id: "opencode", name: "OpenCode", models: [{ id: "default", name: "default" }], pickable: true };
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ModelPicker
        catalog={[claude, loading]}
        harness="claude"
        model="opus"
        label="Opus 5.5"
        efforts={[]}
        recents={[]}
        onLand={() => {}}
        onCombo={() => {}}
        onHarness={(id) => picked.push(id)}
        onEffort={() => {}}
        quick={{}}
      />,
    ),
  );
  await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
  await settle();
  const doc = dom.window.document;
  const tab = doc.querySelector<HTMLElement>('.acpmux-cols-tab[role="tab"][aria-label="OpenCode"]')!;
  await act(async () => tab.click());
  await settle();
  expect(picked).toEqual([]);
  expect(doc.querySelector('.acpmux-cols [role="listbox"]')?.textContent).toContain("No models yet");
});

// Lucas 2026-11-25: "the icon for account on gemini/antigravity should be gemini". The account
// avatar's badge on a tab whose routes are other products draws the tab's brand.
test("the Gemini tab's account avatar wears the Gemini mark on its Antigravity route", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
  const geminiCli = {
    id: "gemini",
    name: "Gemini CLI",
    mark: "gemini",
    models: [{ id: "gemini-3.8-flash", name: "3.8 Flash" }],
    pickable: true,
  };
  const antigravity = {
    id: "antigravity",
    name: "Antigravity",
    mark: "antigravity",
    models: [{ id: "gemini-4-neon", name: "Gemini 4 Neon" }],
    pickable: true,
  };
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ModelPicker
        catalog={[claude, geminiCli, antigravity]}
        harness="antigravity"
        model="gemini-4-neon"
        label="Gemini 4 Neon"
        efforts={[]}
        recents={[]}
        onLand={() => {}}
        onCombo={() => {}}
        onHarness={() => {}}
        onEffort={() => {}}
        quick={{}}
      />,
    ),
  );
  await act(async () => host.querySelector<HTMLButtonElement>("button")!.click());
  await settle();
  const badge = dom.window.document.querySelector(".acpmux-cols-corner .acpmux-cols-avatar-badge [data-agent]");
  expect(badge?.getAttribute("data-agent")).toBe("gemini");
});
