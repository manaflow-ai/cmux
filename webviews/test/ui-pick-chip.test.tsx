// An inspector pick in the composer and in a sent message (composer/UIPickChip.tsx). Leo, 2026-11-08,
// after pasting a pick's report: "i just used the inspector. i think it could be more ergonomic...
// clicking it should be able to show the raw/full thing... idk how possible it'd be to also be able
// to have a well-designed button to click to re-collapse it too."
// - The pick draws as a chip naming the element and a snippet of its text, never the report's page.
// - A click opens the whole report in place; Collapse folds it; Escape folds it, focus on the face.
// - The prompt still sends the whole report, byte for byte.
// - A sent message draws the pick as the same chip, opening in place in its body.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { PromptContentPart } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

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
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

/// The report Leo pasted, as UIInspectorController.swift pageReport writes it.
const REPORT = [
  "cmux NEXT app-owned webview selection",
  "Component: span",
  "Source: unavailable",
  "Selector: span",
  "Text: the Cloud version-check and Cloud Desktop fixes;",
  'Computed styles: ["color": "rgb(229, 229, 229)", "display": "inline"]',
  'DOM: <span class="cv-li__text">the Cloud version-check and Cloud Desktop fixes;</span>',
].join("\n");

const SELECTION = { id: "ui-pointer-6F1C", name: "UI: span", text: REPORT };

async function render(node: React.ReactNode) {
  const { createRoot } = await import("react-dom/client");
  root ??= createRoot(host);
  await act(async () => root!.render(node));
}

function click(node: Element) {
  act(() => {
    node.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true }));
  });
}

/// Opens the chip with a click and checks the whole report shows in place; then the collapse
/// button folds it, and Escape folds it with focus back on the face.
function opensAndFolds(chip: HTMLElement) {
  const face = chip.querySelector<HTMLButtonElement>("button[aria-expanded]")!;
  expect(face).toBeTruthy();
  click(face);
  expect(chip.hasAttribute("data-open")).toBe(true);
  expect(face.getAttribute("aria-expanded")).toBe("true");
  // In place: the report is in the chip itself, no sheet over the pane.
  expect(dom.window.document.querySelector('[role="dialog"]')).toBeNull();
  const shown = chip.querySelector('[role="document"]')!.textContent ?? "";
  expect(shown).toBe(REPORT);
  const collapse = [...chip.querySelectorAll("button")].find((button) => button.textContent === "Collapse");
  expect(collapse).toBeTruthy();
  click(collapse!);
  expect(chip.hasAttribute("data-open")).toBe(false);
  expect(face.getAttribute("aria-expanded")).toBe("false");
  click(face);
  expect(chip.hasAttribute("data-open")).toBe(true);
  act(() => {
    chip
      .querySelector('[role="document"]')!
      .dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  });
  expect(chip.hasAttribute("data-open")).toBe(false);
  expect(dom.window.document.activeElement).toBe(face);
}

test("an inspector pick in the composer is a chip of its element and a snippet of its text", async () => {
  const { designSelectionChips } = await import("../src/agent-session/acpmux/designSelection");
  const { AttachmentStrip } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
  await render(
    <AttachmentStrip attachments={designSelectionChips(SELECTION)} onRemove={() => {}} onExpand={() => {}} />,
  );
  const chip = host.querySelector<HTMLElement>('[data-chip-kind="ui"]');
  expect(chip).toBeTruthy();
  const face = chip!.querySelector<HTMLButtonElement>("button[aria-expanded]")!;
  const title = face.querySelector(".acpmux-paste-chip__title")!.textContent;
  expect(title).toStartWith("span · “the Cloud version-check");
  expect(title).toEndWith("…”");
  expect(face.querySelector(".acpmux-text-card__label")!.textContent).toBe("UI element");
  // Never the report's page of first lines.
  expect(chip!.textContent).not.toContain("cmux NEXT app-owned webview selection");
  expect(face.getAttribute("aria-label")).toContain("span");
  opensAndFolds(chip!);
});

test("the prompt still sends the whole report, exactly", async () => {
  const { designSelectionChips } = await import("../src/agent-session/acpmux/designSelection");
  const { promptText } = await import("../src/agent-session/acpmux/attachments");
  const [chip] = designSelectionChips(SELECTION);
  expect(promptText("Why is this cut off?", [chip!])).toBe(
    `Why is this cut off?\n\nUI: span\n\`\`\`\n${REPORT}\n\`\`\``,
  );
});

test("a sent message draws the pick as the chip, opening in place in its body", async () => {
  const { designSelectionChips } = await import("../src/agent-session/acpmux/designSelection");
  const { promptText } = await import("../src/agent-session/acpmux/attachments");
  const { PromptTyped } = await import("../src/agent-session/acpmux/conversation/PromptText");
  const [pick] = designSelectionChips(SELECTION);
  const sent = promptText("Why is this cut off?", [pick!]);
  await render(
    <div className="cv-user">
      <PromptTyped text={sent} show={(text) => text} />
    </div>,
  );
  const chip = host.querySelector<HTMLElement>('.cv-user [data-chip-kind="ui"]');
  expect(chip).toBeTruthy();
  expect(host.textContent).toContain("Why is this cut off?");
  // The fence and the report's lines are not drawn as a code block beside the chip.
  expect(host.querySelector("pre")).toBeNull();
  expect(chip!.querySelector(".acpmux-paste-chip__title")!.textContent).toStartWith("span · “the Cloud version-check");
  opensAndFolds(chip!);
});

test("a pick placed in the prompt's text draws as the chip in the sent message's inline parts", async () => {
  const { designSelectionChips } = await import("../src/agent-session/acpmux/designSelection");
  const { inlineToken } = await import("../src/agent-session/acpmux/attachments");
  const { inlinePrompt } = await import("../src/agent-session/acpmux/inlinePrompt");
  const { InlinePromptContent } = await import("../src/agent-session/acpmux/conversation/InlinePromptContent");
  const [pick] = designSelectionChips(SELECTION);
  // The default send: the composer placed the pick in the text, so the bubble draws its parts.
  const built = inlinePrompt(`Why is this cut off? ${inlineToken(pick!.id)} thanks`, [pick!])!;
  expect(built).toBeTruthy();
  // As acpmux gives it back after a reload too: the part carries its name and stored text only.
  for (const parts of [built.parts, built.parts.map((part) => ({ ...part, attachmentId: undefined }))]) {
    await render(
      <div className="cv-user">
        <InlinePromptContent
          rowId="pick-row"
          parts={parts as PromptContentPart[]}
          show={(text) => text}
          renderImage={() => null}
        />
      </div>,
    );
    const chip = host.querySelector<HTMLElement>('.cv-user [data-chip-kind="ui"]');
    expect(chip).toBeTruthy();
    expect(host.textContent).toContain("Why is this cut off?");
    expect(host.textContent).toContain("thanks");
    // Not a file or paste chip of the report, and no fence drawn beside it.
    expect(host.querySelector(".cv-user__file-open")).toBeNull();
    expect(host.querySelector("pre")).toBeNull();
    expect(chip!.querySelector(".acpmux-paste-chip__title")!.textContent).toStartWith(
      "span · “the Cloud version-check",
    );
    opensAndFolds(chip!);
  }
});

test("text that is not a pick draws as it did", async () => {
  const { PromptTyped } = await import("../src/agent-session/acpmux/conversation/PromptText");
  await render(<PromptTyped text={"notes.md\n```md\n# Title\n```"} show={(text) => text} />);
  expect(host.querySelector("[data-chip-kind]")).toBeNull();
  expect(host.querySelector("pre")).toBeTruthy();
});

test("a pick in a huge legacy prompt still draws as the chip, the text around it literal", async () => {
  const { designSelectionChips } = await import("../src/agent-session/acpmux/designSelection");
  const { promptText } = await import("../src/agent-session/acpmux/attachments");
  const { PromptTyped } = await import("../src/agent-session/acpmux/conversation/PromptText");
  const { HUGE_PROMPT_CHARS, isHugePrompt } = await import("../src/agent-session/acpmux/conversation/promptCollapse");
  const [pick] = designSelectionChips(SELECTION);
  // A pasted log past the huge threshold, then the pick, as a legacy send joined them.
  const log = `# Log\n${"x".repeat(HUGE_PROMPT_CHARS)}`;
  const sent = promptText(log, [pick!]);
  expect(isHugePrompt(sent)).toBe(true);
  await render(
    <div className="cv-user">
      <PromptTyped text={sent} show={(text) => text} />
    </div>,
  );
  const chip = host.querySelector<HTMLElement>('.cv-user [data-chip-kind="ui"]');
  expect(chip).toBeTruthy();
  // The report is the chip's, not raw fenced text beside it.
  expect(host.textContent).not.toContain("```");
  // The huge text before it still draws as one literal node: no Markdown heading.
  expect(host.querySelector("h1")).toBeNull();
  expect(host.textContent).toContain("# Log");
  opensAndFolds(chip!);
});

/// A placed pick on line 15 of a prompt past the fold's twenty lines, as acpmux gives it back.
async function foldedPickParts() {
  const { designSelectionChips } = await import("../src/agent-session/acpmux/designSelection");
  const { inlineToken } = await import("../src/agent-session/acpmux/attachments");
  const { inlinePrompt } = await import("../src/agent-session/acpmux/inlinePrompt");
  const [pick] = designSelectionChips(SELECTION);
  const lines = (from: number, count: number) =>
    Array.from({ length: count }, (_, index) => `line ${from + index}`).join("\n");
  const built = inlinePrompt(`${lines(1, 14)}\n${inlineToken(pick!.id)}\n${lines(16, 20)}`, [pick!])!;
  return built.parts.map((part) => ({ ...part, attachmentId: undefined })) as PromptContentPart[];
}

// Review of cmux#38447 at 105d5c58: "A pick around line 15 of a folded message therefore expands
// behind the twenty-line clamp, hiding report content and Collapse."
test("opening a pick in a folded message opens the message's fold too", async () => {
  const { InlinePromptContent } = await import("../src/agent-session/acpmux/conversation/InlinePromptContent");
  const parts = await foldedPickParts();
  await render(
    <div className="cv-user">
      <InlinePromptContent rowId="folded-pick" parts={parts} show={(text) => text} renderImage={() => null} />
    </div>,
  );
  const body = host.querySelector(".cv-user__text")!;
  expect(body.classList.contains("is-clamped")).toBe(true);
  const chip = host.querySelector<HTMLElement>('[data-chip-kind="ui"]')!;
  click(chip.querySelector("button[aria-expanded]")!);
  expect(chip.hasAttribute("data-open")).toBe(true);
  expect(host.querySelector(".cv-user__text")!.classList.contains("is-clamped")).toBe(false);
});

// Review of cmux#38447 at 105d5c58: "Selecting a match in computed styles or DOM leaves the report
// closed and the matching text undrawn."
test("Find's current match in a pick's report opens the chip and the fold, and repaints", async () => {
  const { InlinePromptContent } = await import("../src/agent-session/acpmux/conversation/InlinePromptContent");
  const { FindReveal, foldFind } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const parts = await foldedPickParts();
  let repaints = 0;
  for (const needle of ['"display": "inline"', 'class="cv-li__text"']) {
    const reveal = {
      rowId: `find-pick-${needle.length}`,
      card: false,
      needle: foldFind(needle),
      repaint: () => repaints++,
    };
    await render(
      <FindReveal.Provider value={reveal}>
        <div className="cv-user">
          <InlinePromptContent rowId={reveal.rowId} parts={parts} show={(text) => text} renderImage={() => null} />
        </div>
      </FindReveal.Provider>,
    );
    const chip = host.querySelector<HTMLElement>('[data-chip-kind="ui"]')!;
    expect(chip.hasAttribute("data-open")).toBe(true);
    expect(host.querySelector(".cv-user__text")!.classList.contains("is-clamped")).toBe(false);
    expect(chip.querySelector('[role="document"]')!.textContent).toContain(needle);
    act(() => root?.unmount());
    root = undefined;
  }
  expect(repaints).toBe(2);
});

test("a sent pick's chip stays open across the row's remount, as its file chip did", async () => {
  const { InlinePromptContent } = await import("../src/agent-session/acpmux/conversation/InlinePromptContent");
  const parts = await foldedPickParts();
  const draw = () =>
    render(
      <div className="cv-user">
        <InlinePromptContent rowId="remount-pick" parts={parts} show={(text) => text} renderImage={() => null} />
      </div>,
    );
  await draw();
  click(host.querySelector('[data-chip-kind="ui"] button[aria-expanded]')!);
  act(() => root?.unmount());
  root = undefined;
  await draw();
  expect(host.querySelector('[data-chip-kind="ui"]')!.hasAttribute("data-open")).toBe(true);
});

test("Find reads a placed pick as its chip draws it: the report, not its name and fence", async () => {
  const { findBodyText } = await import("../src/agent-session/acpmux/conversation/promptCollapse");
  const text = findBodyText(await foldedPickParts());
  expect(text).toContain(REPORT);
  expect(text).not.toContain("UI: span");
  expect(text).not.toContain("```");
});

test("a sent pick is estimated as its chip, not its report's lines", async () => {
  const { layoutConversation, SENT_UI_PICK_CHIP } = await import("../src/agent-session/acpmux/model");
  const { designSelectionChips } = await import("../src/agent-session/acpmux/designSelection");
  const { inlineToken, promptText } = await import("../src/agent-session/acpmux/attachments");
  const { inlinePrompt } = await import("../src/agent-session/acpmux/inlinePrompt");
  const [pick] = designSelectionChips(SELECTION);
  const height = (row: object) =>
    layoutConversation([{ id: "u", version: 1, at: 0, kind: "user", ...row }] as never, 720).heights[0]!;
  const plain = height({ text: "Why is this cut off?" });
  const chip = SENT_UI_PICK_CHIP.height + 2 * SENT_UI_PICK_CHIP.marginY;
  // Sent with the strip (the report a fenced block of the text) and placed in the text: one line and
  // the chip, never the report's seven lines in a code block.
  expect(height({ text: promptText("Why is this cut off?", [pick!]) })).toBeCloseTo(plain + chip, 0);
  const placed = inlinePrompt(`Why is this cut off?\n${inlineToken(pick!.id)}`, [pick!])!;
  expect(height({ text: "Why is this cut off?", inlineParts: placed.parts })).toBeCloseTo(plain + chip, 0);
});

// Review of cmux#38447 at 9cd0e214: "Searching `UI: span` therefore produces an invisible result;
// searching `span` counts an extra occurrence, shifting highlights and repeating the final match."
test("Find reads a legacy prompt's pick as its chip draws it: the report, not its name and fence", async () => {
  const { designSelectionChips } = await import("../src/agent-session/acpmux/designSelection");
  const { promptText } = await import("../src/agent-session/acpmux/attachments");
  const { findMatchesIncremental } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const [pick] = designSelectionChips(SELECTION);
  const rows = [
    { id: "legacy-pick", version: 1, at: 0, kind: "user", text: promptText("Why is this span cut off?", [pick!]) },
  ];
  const count = (query: string) => findMatchesIncremental(rows as never, query, undefined, "strip").matches.length;
  // The name line and the fence draw nowhere (the chip's face is outside Find).
  expect(count("UI: span")).toBe(0);
  expect(count("```")).toBe(0);
  // "span": once in the typed words, then each time in the report the chip opens to.
  expect(count("span")).toBe(1 + REPORT.split("span").length - 1);
  expect(count("Computed styles")).toBe(1);
});
