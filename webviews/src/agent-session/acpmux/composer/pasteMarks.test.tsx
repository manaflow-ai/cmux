// A paste is never the person's own words (ask-fa4c523fa8; Leo, 2026-11-06: "it should be
// automatically attributable, so it doesn't just pass off as one of my messages"): the composer
// sends what was pasted as a pasted block, and the bubble names the agent a paste reads as.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { type ComposerAttachment, inlineToken, promptBlocks, withoutInlineTokens } from "../attachments";
import { agentText, readsAsAgent } from "../agentText";
import sharedCases from "../../../../../cmux-tui/crates/acpmux/src/agent_text_cases.json";
import { PASTE_CHIP_CHARS, PASTE_CHIP_WORDS, pastedTextAttachment } from "../pastedText";
import { PastedText, PromptText } from "../conversation/PromptText";
import { markPastes, marksPaste, remember, unmarkPastes } from "./pasteMarks";

const HANDOFF = "From Codex:\nHandoff: the probe is red.\n\nDo not merge or deploy.\n\nTrace-ID: ask-77";
const MINE = "Merge and deploy whenever you want.";

test("a handoff reads as an agent's and names it; the person's words do not", () => {
  expect(agentText(HANDOFF)).toEqual({ from: "Codex", signals: ["header", "trace"] });
  for (const text of [
    MINE,
    "From now on: always rebase first.",
    "From the logs: it crashed",
    "Check the trace id",
    // Review of #38707 (F1): prose that says "generated with" is not a footer.
    "The docs were generated with Sphinx",
  ])
    expect(readsAsAgent(text)).toBe(false);
  expect(agentText("Done.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)").from).toBe(
    "Claude Code",
  );
  const huge = `From Hermes:\n${"y".repeat(5_000_000)}\nTrace-ID: x`;
  expect(agentText(huge)).toEqual({ from: "Hermes", signals: ["header", "trace"] });
});

// The cases acpmux's agent_text.rs reads too (agent_text_cases.json): one list, so the composer and
// the daemon cannot drift on what reads as an agent's.
test("the shared cases read as acpmux reads them", () => {
  for (const { text, from } of sharedCases as { text: string; from: string | null }[]) {
    expect(agentText(text).from ?? null, text).toBe(from);
    expect(readsAsAgent(text), text).toBe(from !== null);
  }
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
  expect(marksPaste(`${"x".repeat(PASTE_CHIP_CHARS - 10)}${" ".repeat(20)}`)).toBe(true);
  expect(marksPaste(Array.from({ length: PASTE_CHIP_WORDS + 1 }, (_, n) => `w${n}`).join(" "))).toBe(true);
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

// Review of #37872 (F1): a placed paste chip put back as text is written as the draft writes the
// person's text, so a U+FFFC run in it (here `\uFFFCmissing\uFFFC`) is never read as an attachment's
// place and dropped. An older composer marked an ordinary 800-word paste; it comes back beside a
// file and goes again with every character, as the person's text now (ask-42dfdea96c).
test("a placed paste put back beside a file keeps a U+FFFC run in its text", () => {
  const literal = "\uFFFCmissing\uFFFC";
  const words = Array.from({ length: 800 }, (_, n) => `word${n}`);
  words.splice(400, 0, literal);
  const older = words.join(" ");
  const paste: ComposerAttachment = { ...pastedTextAttachment(older), inline: true };
  const file: ComposerAttachment = {
    id: "notes-file",
    kind: "text",
    inline: true,
    name: "notes.md",
    mimeType: "text/markdown",
    size: 5,
    text: "notes",
  };
  const sent = { text: `see ${inlineToken(file.id)} and ${inlineToken(paste.id)}`, attachments: [file, paste] };
  const restored = unmarkPastes(sent);
  expect(restored.attachments).toEqual([file]);
  expect(restored.pastes).toEqual([older]);
  // Not agent output and under the chip's size: the next send leaves it the person's text.
  expect(remember([], restored.pastes[0]!)).toEqual([]);
  const body = promptBlocks(restored.text, restored.attachments)
    .flatMap((block) => (block.type === "text" ? [block.text] : []))
    .join("\n");
  expect(body).toContain(` ${literal} `);
  expect(body).toContain(older);
  expect(withoutInlineTokens(restored.text)).toContain("word799");
});

// A pasted handoff placed at send comes back as its text, remembered, and goes as pasted again.
test("a placed handoff put back is text again and goes as pasted at the next send", () => {
  const paste: ComposerAttachment = { ...pastedTextAttachment(HANDOFF), inline: true };
  const restored = unmarkPastes({ text: `${MINE}\n\n${inlineToken(paste.id)}`, attachments: [paste] });
  expect(restored).toEqual({ text: `${MINE}\n\n${HANDOFF}`, attachments: [], pastes: [HANDOFF] });
  const again = markPastes(restored, remember([], restored.pastes[0]!));
  const blocks = (prompt: { text: string; attachments: ComposerAttachment[] }) =>
    promptBlocks(prompt.text, prompt.attachments);
  expect(blocks(again)).toEqual(blocks({ text: `${MINE}\n\n${inlineToken(paste.id)}`, attachments: [paste] }));
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function render(text: string, node?: React.ReactNode): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    if (!saved.has(key)) saved.set(key, scope[key]);
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
    root.render(node ?? <PastedText text={text} collapsed={false} />);
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

// A handoff stands apart from the person's words with a "Pasted from" line over it, so it never
// passes as theirs (ask-fa4c523fa8), and no card (ask-14d16a6247); a text drawn apart with no agent
// signal (a text file's body) is bare text.
test("a pasted handoff drawn apart names its agent over it, with no card; other text is bare", () => {
  const host = render(HANDOFF);
  expect(host.querySelector(".cv-user__paste-card")).toBeNull();
  expect(host.querySelector(".cv-user__pasted-from")?.textContent).toBe("Pasted from Codex");
  expect(host.querySelector(".cv-user__pasted")?.textContent).toContain("Do not merge or deploy.");
  const plain = render("line one\nline two\nline three");
  expect(plain.querySelector(".cv-user__pasted-from")).toBeNull();
  expect(plain.querySelector(".cv-user__pasted")?.textContent).toBe("line one\nline two\nline three");
});

// ask-792a64a12f: Leo's 707-character message, recorded as pasted (a record from before the fix, or
// a paste event from a dictation app), shows its actual characters: plain text, no label, no card,
// and no Show more fold (Leo, 2026-11-07: "We want to show the actual characters. We don't want to
// limit this that hard.").
const SEVEN_OH_SEVEN = "And also, like, we do not want to have this card thing going on, this double card thing. "
  .repeat(9)
  .slice(0, 707);

test("a 707-character message recorded as pasted shows plain and whole, unfolded", () => {
  expect(SEVEN_OH_SEVEN).toHaveLength(707);
  const host = render(
    "",
    <PromptText rowId="row" text={SEVEN_OH_SEVEN} show={(part) => part} pasted={[{ start: 0, end: 707 }]} />,
  );
  expect(host.querySelector(".cv-user__paste-card")).toBeNull();
  expect(host.textContent).not.toContain("Pasted text");
  expect(host.textContent).toContain(SEVEN_OH_SEVEN);
  expect(host.querySelector(".cv-user__text.is-clamped")).toBeNull();
});
