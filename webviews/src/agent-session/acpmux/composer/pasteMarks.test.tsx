// A paste is never the person's own words (ask-fa4c523fa8; Leo, 2026-11-06: "it should be
// automatically attributable, so it doesn't just pass off as one of my messages"): the composer
// sends what was pasted as a pasted block, and the bubble names the agent a paste reads as.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { promptBlocks } from "../attachments";
import { agentText, readsAsAgent } from "../agentText";
import { PasteChip, PromptText } from "../conversation/PromptText";
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

// (d) A typed prompt, and an ordinary paste in it (a path, a few lines, a dictation app's paragraph),
// stay the person's own text (ask-42dfdea96c): only agent output or an oversized paste is marked.
test("typed text and an ordinary paste stay the person's", () => {
  expect(marksPaste("src/app.ts")).toBe(false);
  expect(marksPaste("one\ntwo")).toBe(false);
  expect(marksPaste("x".repeat(515))).toBe(false);
  // Review of #37516 (F3): measured untrimmed, as the chip was, so space around a paste just past
  // the limit cannot drop its mark when Edit in Prompt puts it back.
  expect(marksPaste(`${"x".repeat(9_990)}${" ".repeat(20)}`)).toBe(true);
  expect(marksPaste(Array.from({ length: 751 }, (_, n) => `w${n}`).join(" "))).toBe(true);
  const prompt = { text: `${MINE} see src/app.ts`, attachments: [] };
  expect(markPastes(prompt, remember([], "src/app.ts"))).toBe(prompt);
  const blocks = promptBlocks(prompt.text, prompt.attachments);
  expect(blocks).toEqual([{ type: "text", text: prompt.text }]);
});

// Review of #37191: a paste is found however often it was pasted, whatever the trim did to the
// space around it, and with the person's words typed around it.
test("each copy of a paste pasted twice goes as pasted", () => {
  const pastes = remember(remember([], HANDOFF), HANDOFF);
  const marked = markPastes({ text: `${HANDOFF}\n\n${MINE}\n\n${HANDOFF}`, attachments: [] }, pastes);
  const texts = promptBlocks(marked.text, marked.attachments).flatMap((block) =>
    block.type === "text" ? [[block.text.trim(), Boolean(block._meta)]] : [],
  );
  expect(texts).toEqual([
    [HANDOFF, true],
    [MINE, false],
    [HANDOFF, true],
  ]);
});

test("a paste pasted once is placed once, a second typed copy stays typed", () => {
  const marked = markPastes({ text: `${HANDOFF}\n${HANDOFF}`, attachments: [] }, remember([], HANDOFF));
  expect(marked.attachments).toHaveLength(1);
});

test("a paste with line breaks around it is found in the trimmed prompt, words typed around it stay", () => {
  const paste = `\n${HANDOFF}\n\n`;
  const marked = markPastes({ text: `${MINE} ${HANDOFF.trim()} thanks`, attachments: [] }, remember([], paste));
  const blocks = promptBlocks(marked.text, marked.attachments).flatMap((block) =>
    block.type === "text" ? [[block.text.trim(), Boolean(block._meta)]] : [],
  );
  expect(blocks).toEqual([
    [MINE, false],
    [HANDOFF, true],
    ["thanks", false],
  ]);
});

test("a paste the person edited, or one no longer in the draft, is theirs", () => {
  const prompt = { text: HANDOFF.replace("Do not", "Please do"), attachments: [] };
  expect(markPastes(prompt, remember([], HANDOFF))).toBe(prompt);
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function render(text: string, node?: React.ReactNode): HTMLElement {
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
    root.render(node ?? <PasteChip rowId="row" index={0} text={text} needle="" onOpen={() => {}} />);
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

/// Runs `check` with the sent bubble drawing pastes as `look` (sentPasteLook).
function withPasteLook(look: string, check: () => void) {
  const before = globalThis.cmuxExperiments;
  globalThis.cmuxExperiments = { ...before, "sent-paste-look": look };
  try {
    check();
  } finally {
    globalThis.cmuxExperiments = before;
  }
}

test("a pasted handoff's card names the agent it reads as, never the person", () =>
  withPasteLook("card", () => {
    const host = render(HANDOFF);
    const card = host.querySelector(".cv-user__paste-card")!;
    expect(card.getAttribute("data-agent")).toBe("rule");
    expect(host.querySelector(".cv-user__paste-name")?.textContent).toBe("Pasted from Codex");
  }));

test("a plain paste's card stays Pasted text", () =>
  withPasteLook("card", () => {
    const host = render("line one\nline two\nline three");
    expect(host.querySelector(".cv-user__paste-card")?.hasAttribute("data-agent")).toBe(false);
    expect(host.querySelector(".cv-user__paste-name")?.textContent).toBe("Pasted text");
  }));

// Drawn as the bubble's own text (the default), a handoff keeps a "Pasted from" line over it, so it
// never passes as the person's words; a plain paste has none.
test("a pasted handoff drawn as text names its agent over it; a plain paste is bare text", () =>
  withPasteLook("text", () => {
    const host = render(HANDOFF);
    expect(host.querySelector(".cv-user__paste-card")).toBeNull();
    expect(host.querySelector(".cv-user__pasted-from")?.textContent).toBe("Pasted from Codex");
    expect(host.querySelector(".cv-user__pasted")?.textContent).toContain("Do not merge or deploy.");
    const plain = render("line one\nline two\nline three");
    expect(plain.querySelector(".cv-user__pasted-from")).toBeNull();
    expect(plain.querySelector(".cv-user__pasted")?.textContent).toBe("line one\nline two\nline three");
  }));

// ask-792a64a12f: Leo's 707-character message, recorded as pasted (a record from before the fix, or
// a paste event from a dictation app), shows its actual characters: plain text, no label, no card,
// and no Show more fold (Leo, 2026-11-07: "We want to show the actual characters. We don't want to
// limit this that hard.").
const SEVEN_OH_SEVEN = "And also, like, we do not want to have this card thing going on, this double card thing. "
  .repeat(9)
  .slice(0, 707);

// Under the shipped look (`text`), named here: another file in the same run may leave the card arm on.
test("a 707-character message recorded as pasted shows plain and whole, unfolded", () =>
  withPasteLook("text", () => {
    expect(SEVEN_OH_SEVEN).toHaveLength(707);
    const host = render(
      "",
      <PromptText rowId="row" text={SEVEN_OH_SEVEN} show={(part) => part} pasted={[{ start: 0, end: 707 }]} />,
    );
    expect(host.querySelector(".cv-user__paste-card")).toBeNull();
    expect(host.textContent).not.toContain("Pasted text");
    expect(host.textContent).toContain(SEVEN_OH_SEVEN);
    expect(host.querySelector(".cv-user__text.is-clamped")).toBeNull();
  }));
