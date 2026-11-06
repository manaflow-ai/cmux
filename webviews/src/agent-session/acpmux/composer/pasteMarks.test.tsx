// A paste is never the person's own words (ask-fa4c523fa8; Leo, 2026-11-06: "it should be
// automatically attributable, so it doesn't just pass off as one of my messages"): the composer
// sends what was pasted as a pasted block, and the bubble names the agent a paste reads as.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { promptBlocks } from "../attachments";
import { agentText, readsAsAgent } from "../agentText";
import { PasteChip } from "../conversation/PromptText";
import { markPastes, marksPaste, remember } from "./pasteMarks";

const HANDOFF = "From Codex:\nHandoff: the probe is red.\n\nDo not merge or deploy.\n\nTrace-ID: ask-77";
const MINE = "Merge and deploy whenever you want.";

test("a handoff reads as an agent's and names it; the person's words do not", () => {
  expect(agentText(HANDOFF)).toEqual({ from: "Codex", signals: ["header", "trace"] });
  for (const text of [MINE, "From now on: always rebase first.", "From the logs: it crashed", "Check the trace id"])
    expect(readsAsAgent(text)).toBe(false);
  expect(agentText("Done.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)").from).toBe(
    "Claude Code",
  );
  const huge = `From Hermes:\n${"y".repeat(5_000_000)}\nTrace-ID: x`;
  expect(agentText(huge)).toEqual({ from: "Hermes", signals: ["header", "trace"] });
});

// (a) The person pastes a Codex handoff and types their own line: the paste goes as its own pasted
// block, the person's line as typed text, and the text the agent gets is the same words.
test("a pasted handoff goes as a pasted block beside the person's typed line", () => {
  const pastes = remember([], HANDOFF);
  const marked = markPastes({ text: `${MINE}\n\n${HANDOFF}`, attachments: [] }, pastes);
  const blocks = promptBlocks(marked.text, marked.attachments);
  const texts = blocks.flatMap((block) => (block.type === "text" ? [block] : []));
  expect(texts.map((block) => block.text.trim())).toEqual([MINE, HANDOFF]);
  expect(texts[0]._meta).toBeUndefined();
  expect(texts[1]._meta).toEqual({ cmux: { pasted: true } });
});

// (d) A typed prompt, and a short one-line paste in it (a path), stay the person's own text.
test("typed text and a short one-line paste stay the person's", () => {
  expect(marksPaste("src/app.ts")).toBe(false);
  expect(marksPaste("one\ntwo")).toBe(true);
  expect(marksPaste("x".repeat(200))).toBe(true);
  const prompt = { text: `${MINE} see src/app.ts`, attachments: [] };
  expect(markPastes(prompt, remember([], "src/app.ts"))).toBe(prompt);
  const blocks = promptBlocks(prompt.text, prompt.attachments);
  expect(blocks).toEqual([{ type: "text", text: prompt.text }]);
});

test("a paste the person edited, or one no longer in the draft, is theirs", () => {
  const prompt = { text: HANDOFF.replace("Do not", "Please do"), attachments: [] };
  expect(markPastes(prompt, remember([], HANDOFF))).toBe(prompt);
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function render(text: string): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
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
  const host = dom.window.document.getElementById("root")!;
  act(() => {
    root = createRoot(host);
    root.render(<PasteChip rowId="row" index={0} text={text} needle="" onOpen={() => {}} />);
  });
  return host;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("a pasted handoff's card names the agent it reads as, never the person", () => {
  const host = render(HANDOFF);
  const card = host.querySelector(".cv-user__paste-card")!;
  expect(card.getAttribute("data-agent")).toBe("rule");
  expect(host.querySelector(".cv-user__paste-name")?.textContent).toBe("Pasted from Codex");
});

test("a plain paste's card stays Pasted text", () => {
  const host = render("line one\nline two\nline three");
  expect(host.querySelector(".cv-user__paste-card")?.hasAttribute("data-agent")).toBe(false);
  expect(host.querySelector(".cv-user__paste-name")?.textContent).toBe("Pasted text");
});
