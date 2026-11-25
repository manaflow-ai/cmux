// l10n-allow-file: the status copy is supplied by the pane's string table.
// A look's thinking glyph (agentPane.display.thinking.glyph, a cmux.particles/1 document) reaches the
// chat's two surfaces through the host's display push (chatDisplay.ts `setChatDisplay`), the way a look
// install or `cmux settings set` sends it: the live status line plays it before its words, and Jump to
// latest plays it while the agent works with jumpButton "glyph", at glyphSize points a dot. Unset, the
// page mounts nothing new. A new document swaps the running glyph in place (Leo, 2026-11-19: "the dots
// and the way it moves changes a lot").
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Thinking } from "./Thinking";
import { JumpToLatest } from "../VirtualTranscript";
import { setChatDisplay } from "../chatDisplay";
import {
  resolveThinkingLook,
  THINKING_GLYPH_KEY,
  THINKING_GLYPH_SIZE_KEY,
  THINKING_JUMP_BUTTON_KEY,
} from "./thinkingLook";
import { glyphExtent, glyphTrigger, setLiveGlyphTrigger } from "./thinkingGlyphModel";
import { orbitGlyph, tradeGlyph, waveGlyph } from "./thinkingGlyphSamples";
import { parseChoreography } from "../../../apps/scene/choreography";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
});

afterEach(async () => {
  act(() => root?.unmount());
  setChatDisplay({});
  setLiveGlyphTrigger("thinking");
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const dots = (selector: string) => container.querySelectorAll(`${selector} .cmux-choreography-dot`);
const jump = () => <JumpToLatest shown working lift={0} onJump={() => {}} />;

test("unset, neither the live line nor Jump to latest mounts a glyph", () => {
  act(() => root!.render(<Thinking />));
  expect(container.querySelector(".cv-glyph")).toBeNull();
  act(() => root!.render(jump()));
  expect(container.querySelector(".cv-glyph")).toBeNull();
  expect(container.querySelector(".acpmux-jump-latest")?.hasAttribute("data-working-dots")).toBe(false);
});

test("the look's glyph reaches the live line and swaps live for another look's", () => {
  act(() => setChatDisplay({ [THINKING_GLYPH_KEY]: tradeGlyph }));
  act(() => root!.render(<Thinking />));
  // One span per dot the document allows, each moved only by transform.
  expect(dots(".cv-thinking-glyph").length).toBe(tradeGlyph.particle.max);
  const box = container.querySelector<HTMLElement>(".cv-thinking-glyph")!;
  const extent = glyphExtent(parseChoreography(tradeGlyph)!);
  expect(box.style.width).toBe(`${extent.width}px`);
  expect(box.style.height).toBe(`${extent.height}px`);

  act(() => setChatDisplay({ [THINKING_GLYPH_KEY]: orbitGlyph }));
  expect(dots(".cv-thinking-glyph").length).toBe(orbitGlyph.particle.max);
  act(() => setChatDisplay({ [THINKING_GLYPH_KEY]: waveGlyph }));
  expect(dots(".cv-thinking-glyph").length).toBe(waveGlyph.particle.max);
  // Taken off, the line draws what it drew before.
  act(() => setChatDisplay({}));
  expect(container.querySelector(".cv-glyph")).toBeNull();
});

test("Jump to latest plays the glyph at glyphSize while the agent works", () => {
  act(() =>
    setChatDisplay({
      [THINKING_GLYPH_KEY]: tradeGlyph,
      [THINKING_JUMP_BUTTON_KEY]: "glyph",
      [THINKING_GLYPH_SIZE_KEY]: 2.4,
    }),
  );
  act(() => root!.render(jump()));
  const button = container.querySelector(".acpmux-jump-latest")!;
  expect(button.hasAttribute("data-working-dots")).toBe(true);
  const spans = dots(".cv-jump-glyph");
  expect(spans.length).toBe(tradeGlyph.particle.max);
  expect((spans[0] as HTMLElement).style.width).toBe("2.4px");
  // The old CSS dots are not drawn beside it.
  expect(container.querySelector(".cv-jump-dots")).toBeNull();
  act(() => root!.render(<JumpToLatest shown working={false} lift={0} onJump={() => {}} />));
  expect(container.querySelector(".cv-glyph")).toBeNull();
});

test("a document the player cannot read draws nothing, and jumpButton glyph keeps the arrow", () => {
  const look = resolveThinkingLook({
    [THINKING_GLYPH_KEY]: { $schema: "cmux.particles/2", particle: { size: 3 }, phases: {} },
    [THINKING_JUMP_BUTTON_KEY]: "glyph",
  });
  expect(look.glyph).toBeNull();
  expect(look.jumpButton).toBe("arrow");
  expect(resolveThinkingLook({ [THINKING_GLYPH_SIZE_KEY]: 99 }).glyphSize).toBe(0);
});

test("the trigger follows the agent's activity", () => {
  expect(glyphTrigger({})).toBe("thinking");
  expect(glyphTrigger({ starting: true, kind: "read" })).toBe("turnStart");
  expect(glyphTrigger({ kind: "execute" })).toBe("execute");
  expect(glyphTrigger({ kind: "execute", sendTo: "tests" })).toBe("sendMessage");
  expect(glyphTrigger({ liveState: "writing" })).toBe("other");
});
