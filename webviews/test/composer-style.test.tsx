// l10n-allow-file: test fixture labels, not shipped UI.
// The composer's style (Settings > Agent Chat > Composer Style, cmux.json
// `agentPane.display.composer.style`, the host's `display` event, chatDisplay.ts). Leo 2026-10-21: "we can have the alt composer like chatgpt
// styled but for now just have "minimal" be the claude thing". With no setting the style resolves to
// minimal, Claude Code's composer: no style on the form, the mode, model and effort in the quiet row
// under the box (ComposerFoot). `codex`, the alternate, lays the same pieces out as Codex desktop's: the folder and computer strip (ComposerContext) stands above the box as its
// tray, and the box holds one row under the prompt, + and the chips, then the mic and Send. Both
// styles draw the same components; only the slots differ. test/composer-style-codex.test.ts
// measures the drawn layout in Chromium.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import React, { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
  });
  host = window.document.getElementById("root")!;
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  // The display store outlives this file under `bun test`: back to the default style, minimal.
  const { setChatDisplay } = await import("../src/agent-session/acpmux/chatDisplay");
  setChatDisplay({});
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/** Each composer's chips, counted: both styles must draw this same component. */
const drawn: string[] = [];
function Chips() {
  drawn.push("chips");
  return (
    <div className="acpmux-chips">
      <span className="acpmux-mode acpmux-access">Full access</span>
      <span className="acpmux-picker acpmux-model">GPT-6-Astra High</span>
    </div>
  );
}

/// A new chat before its first send, so the folder and computer strip shows.
const newChat: AcpmuxSnapshot = noChat([], {
  summary: { sessionId: "", harness: "codex", cwd: "/Users/you/src/app" },
});

async function render(style?: "minimal" | "codex") {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const { COMPOSER_STYLE_KEY, setChatDisplay } = await import("../src/agent-session/acpmux/chatDisplay");
  // The host's `display` event, as the pane gets it; no style sent is the default.
  await act(async () => setChatDisplay(style ? { [COMPOSER_STYLE_KEY]: style } : {}));
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={newChat}
        sessionId=""
        chips={Chips}
        onSend={() => true}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        accessory={<button type="button" className="acpmux-mic" aria-label="Dictate" />}
      />,
    ),
  );
  const form = host.querySelector<HTMLFormElement>("form.acpmux-composer")!;
  const box = form.querySelector<HTMLElement>(":scope > .acpmux-composer-box")!;
  const strip = form.querySelector<HTMLElement>(":scope > .acpmux-composer-strip");
  return { form, box, strip };
}

/** The classes of the box's controls row in document order: + first, then the chips, then the actions. */
function rowOrder(box: HTMLElement): string[] {
  const row = box.querySelector<HTMLElement>(".acpmux-composer-bar")!;
  const marks: [string, string][] = [
    ["plus", ".acpmux-composer-plus"],
    ["mode", ".acpmux-access"],
    ["model", ".acpmux-model"],
    ["mic", ".acpmux-mic"],
    ["send", ".acpmux-send"],
  ];
  return marks
    .map(([name, selector]) => [name, row.querySelector(selector)] as const)
    .filter((entry): entry is readonly [string, Element] => entry[1] !== null)
    .sort(([, a], [, b]) => (a.compareDocumentPosition(b) & dom.window.Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1))
    .map(([name]) => name);
}

test("with no setting the style resolves to minimal, Claude Code's composer", async () => {
  const { COMPOSER_STYLE_KEY, DEFAULT_CHAT_DISPLAY, resolveChatDisplay } = await import(
    "../src/agent-session/acpmux/chatDisplay"
  );
  expect(COMPOSER_STYLE_KEY).toBe("agentPane.display.composer.style");
  expect(DEFAULT_CHAT_DISPLAY.composerStyle).toBe("minimal");
  expect(resolveChatDisplay({}).composerStyle).toBe("minimal");
  // A value this page does not know (an older or newer host's) is the default too.
  expect(resolveChatDisplay({ [COMPOSER_STYLE_KEY]: "chatgpt-2" }).composerStyle).toBe("minimal");
  expect(resolveChatDisplay({ [COMPOSER_STYLE_KEY]: "codex" }).composerStyle).toBe("codex");
});

test("with no setting the minimal style draws: no style, no tray, the chips in the quiet row under the box", async () => {
  const { form, box, strip } = await render();
  expect(form.hasAttribute("data-composer-style")).toBe(false);
  // The strip is the default's tab on the card, never the Codex tray.
  expect(strip).not.toBeNull();
  const foot = form.querySelector(":scope > .acpmux-chrome-area > .acpmux-composer-foot, .acpmux-composer-foot");
  expect(foot).not.toBeNull();
  expect(foot!.querySelector(".acpmux-model")).not.toBeNull();
  expect(foot!.querySelector(".acpmux-access")).not.toBeNull();
  // The box keeps +, the mic and Send; no chip.
  expect(box.querySelector(".acpmux-model, .acpmux-access")).toBeNull();
  expect(rowOrder(box)).toEqual(["plus", "mic"]);
});

test("codex: the folder and computer tray stands above the box, and the box's row is + and the mode, then the model, the mic and Send", async () => {
  const { form, box, strip } = await render("codex");
  expect(form.dataset.composerStyle).toBe("codex");
  // The tray: the same location strip, right above the box, naming the folder and this computer.
  expect(strip).not.toBeNull();
  expect(strip!.nextElementSibling).toBe(box);
  const places = [...strip!.querySelectorAll(".acpmux-location-picker")].map((place) => place.textContent ?? "");
  expect(places.some((text) => text.includes("app"))).toBe(true);
  expect(places.some((text) => text.includes("studio"))).toBe(true);
  // No quiet row under the box: every control is in the box's one row.
  expect(form.querySelector(".acpmux-composer-foot")).toBeNull();
  const row = box.querySelector<HTMLElement>(".acpmux-composer-bar")!;
  // The chips keep the plain look's text at rest (composerLocation.css [data-footer-look="plain"]).
  expect(row.dataset.footerLook).toBe("plain");
  // In the DOM the chips come after +; composerStyle.css puts the mode before the model.
  expect(rowOrder(box)).toEqual(["plus", "mode", "model", "mic", "send"]);
});

test("both styles draw the same components: the location strip, +, the one chips component, the mic and Send", async () => {
  const parts = (form: HTMLElement) =>
    [
      ".acpmux-composer-strip .acpmux-composer-context",
      ".acpmux-composer-plus",
      ".acpmux-chips .acpmux-model",
      ".acpmux-chips .acpmux-access",
      ".acpmux-mic",
    ].map((selector) => form.querySelectorAll(selector).length);
  drawn.length = 0;
  const plain = parts((await render()).form);
  const defaultDraws = drawn.length;
  act(() => root?.unmount());
  root = undefined;
  drawn.length = 0;
  const codex = parts((await render("codex")).form);
  expect(defaultDraws).toBeGreaterThan(0);
  expect(drawn.length).toBeGreaterThan(0);
  expect(codex).toEqual(plain);
  expect(codex).toEqual([1, 1, 1, 1, 1]);
});
