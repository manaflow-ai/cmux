// l10n-allow-file: test fixture prompts, not shipped UI.
// A sent message is one continuous text body (ask-14d16a6247; Leo, 2026-11-07, of his dictated
// message pasted in three parts and drawn as three "Pasted text" cards: "Like just don't separate
// these out. And, like, I thought we said, you know, remove these inner bubbles, inner, inner
// cards."). Pasted text is part of the message: no card, no per-paste chevron, no gap past normal
// paragraph spacing, and one fold at the bubble's level. It holds for a transcript that already
// recorded its pastes (`user_message.pasted` ranges, the legacy shape) and for one whose pastes the
// composer placed in its text (`inlineParts`), so it is a render-side fix.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  NodeFilter: dom.window.NodeFilter,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
const { resetTranscriptDisclosure } =
  await import("../src/agent-session/acpmux/conversation/transcriptDisclosureModel");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
type Row = Parameters<typeof UserBubble>[0]["row"];

// Leo's message: one dictation pasted in three parts (1.6K, 503 and 218 characters).
const sentence = (word: string) =>
  `So the ${word} thing I keep noticing is that the transcript separates what I said into pieces, and it should not. `;
const part = (word: string, chars: number) =>
  sentence(word)
    .repeat(Math.ceil(chars / sentence(word).length))
    .slice(0, chars)
    .trim();
const FIRST = part("first", 1600);
const SECOND = part("second", 503);
const THIRD = part("third", 218);

/// Every element that draws a paste apart from the message's text: a card, its label button and
/// chevron, or a block of its own.
const INNER = ".cv-user__paste-block, .cv-user__paste-card, .cv-user__paste, .cv-user__paste-chevron, .cv-user__pasted";

function render(row: Row) {
  resetTranscriptDisclosure();
  act(() => root.render(<UserBubble row={row} text={row.text ?? ""} />));
  return host.querySelector(".cv-user__bubble")!;
}

/// The bubble's text bodies: each run of the message's words drawn as one text.
const bodies = (bubble: Element) => [...bubble.querySelectorAll(".cv-user__typed, .cv-user__markdown")];

test("a sent message recorded with three pasted parts draws as one body with one fold", () => {
  const text = [FIRST, SECOND, THIRD].join("\n");
  const pasted = [
    { start: 0, end: FIRST.length },
    { start: FIRST.length + 1, end: FIRST.length + 1 + SECOND.length },
    { start: FIRST.length + SECOND.length + 2, end: text.length },
  ];
  const bubble = render({ id: "legacy", version: 1, at: Date.now(), kind: "user", text, pasted });
  expect(bubble.querySelectorAll(INNER).length).toBe(0);
  const drawn = bodies(bubble);
  expect(drawn.length).toBe(1);
  expect(drawn[0]!.textContent).toContain(FIRST);
  expect(drawn[0]!.textContent).toContain(SECOND);
  expect(drawn[0]!.textContent).toContain(THIRD);
  // One fold, at the bubble's level: a long message has one Show more and nothing else to open.
  expect(bubble.querySelectorAll(".cv-user__more").length).toBe(1);
  expect(bubble.querySelectorAll("[aria-expanded]").length).toBe(1);
});

test("a sent message whose three pastes the composer placed reads as the draft did, in one body", () => {
  const paste = (text: string) => ({ kind: "pasted", placed: true, text });
  const inlineParts = [
    paste(FIRST),
    { kind: "text", text: " " },
    paste(SECOND),
    { kind: "text", text: " " },
    paste(THIRD),
  ];
  const text = [FIRST, " ", SECOND, " ", THIRD].join("\n");
  const bubble = render({ id: "placed", version: 1, at: Date.now(), kind: "user", text, inlineParts } as Row);
  expect(bubble.querySelectorAll(INNER).length).toBe(0);
  const drawn = bodies(bubble);
  expect(drawn.length).toBe(1);
  // As typed: the words between the pastes are the draft's own, and no line is added between them.
  expect(drawn[0]!.textContent).toBe(`${FIRST} ${SECOND} ${THIRD}`);
  expect(bubble.querySelectorAll(".cv-user__more").length).toBe(1);
});

// A placed text file's body went as a text block with no file behind it, so its chip is the only
// way to read it. Find searches it, as it searched the paste card that drew it before, and the
// current match there opens the chip's disclosure (`prompt:<row>:paste:<index>`) and the fold. At
// 38fb9cad Find left the body out and found nothing.
test("Find matches a sent text file's body behind its chip, and the match opens the chip", async () => {
  const { findMatches, FindReveal } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const { foldFind } = await import("../src/find/fold");
  const { useTranscriptDisclosure } =
    await import("../src/agent-session/acpmux/conversation/transcriptDisclosureModel");
  const body = "notes.txt\n```\nzanzibar rollout plan\n```";
  const inlineParts = [
    { kind: "text", text: "See the notes" },
    { kind: "file", placed: true, name: "notes.txt", mimeType: "text/plain", size: 22, text: body },
  ];
  const row = {
    id: "file-row",
    version: 1,
    at: Date.now(),
    kind: "user",
    text: `See the notes\n${body}`,
    inlineParts,
  } as Row;
  for (const view of ["inline", "strip", "both"] as const)
    expect(findMatches([row], "zanzibar rollout plan", view)).toEqual([
      { rowIndex: 0, rowId: "file-row", occurrence: 0 },
    ]);
  // The typed words, then the body, in the order the bubble draws them.
  expect(findMatches([row], "notes").length).toBe(2);
  const bubble = render(row);
  const opener = bubble.querySelector<HTMLButtonElement>("button.cv-user__file-open")!;
  expect(opener.getAttribute("aria-expanded")).toBe("false");
  expect(bubble.textContent).not.toContain("zanzibar rollout plan");
  let repainted = 0;
  let keyed: boolean | undefined;
  const Keyed = () => {
    keyed = useTranscriptDisclosure(`prompt:${row.id}:paste:1`)[0];
    return null;
  };
  act(() =>
    root.render(
      <FindReveal.Provider
        value={{
          rowId: row.id,
          card: false,
          needle: foldFind("zanzibar rollout plan"),
          repaint: () => repainted++,
        }}
      >
        <UserBubble row={row} text={row.text ?? ""} />
        <Keyed />
      </FindReveal.Provider>,
    ),
  );
  expect(host.querySelector("button.cv-user__file-open")!.getAttribute("aria-expanded")).toBe("true");
  expect(host.querySelector(".cv-user__pasted")?.textContent).toContain("zanzibar rollout plan");
  expect(repainted).toBeGreaterThan(0);
  // The chip's own disclosure, kept by the row's id, as the paste card's was.
  act(() => root.render(<Keyed />));
  expect(keyed).toBe(true);
  // Its label is outside Find, as the paste card's was: Find counts the body, not the chip's name.
  expect(render(row).querySelector("button.cv-user__file-open")!.hasAttribute("data-find-skip")).toBe(true);
  // The strip view keeps the text file in the bubble, and its match opens the chip there too.
  const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
  try {
    act(() => setComposerSettings({ attachmentView: "strip" }));
    render(row);
    expect(host.querySelector(".cv-user__bubble button.cv-user__file-open")!.getAttribute("aria-expanded")).toBe(
      "false",
    );
    act(() =>
      root.render(
        <FindReveal.Provider
          value={{ rowId: row.id, card: false, needle: foldFind("zanzibar rollout plan"), repaint: () => {} }}
        >
          <UserBubble row={row} text={row.text ?? ""} />
        </FindReveal.Provider>,
      ),
    );
    expect(host.querySelector(".cv-user__bubble button.cv-user__file-open")!.getAttribute("aria-expanded")).toBe(
      "true",
    );
  } finally {
    act(() => setComposerSettings({ attachmentView: "inline" }));
  }
  // A match elsewhere in the prompt leaves a closed chip closed.
  resetTranscriptDisclosure();
  act(() =>
    root.render(
      <FindReveal.Provider value={{ rowId: row.id, card: false, needle: foldFind("see the"), repaint: () => {} }}>
        <UserBubble row={row} text={row.text ?? ""} />
      </FindReveal.Provider>,
    ),
  );
  expect(host.querySelector("button.cv-user__file-open")!.getAttribute("aria-expanded")).toBe("false");
});

// A huge prompt collapsed draws only its head, so a text file past it has no chip mounted to open:
// the prompt's own fold opens to the match in its body first.
test("Find's match in a text file past a huge prompt's head opens the fold, then the chip", async () => {
  const { FindReveal } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const { foldFind } = await import("../src/find/fold");
  const { HUGE_PROMPT_CHARS } = await import("../src/agent-session/acpmux/conversation/promptCollapse");
  const typed = "word ".repeat(Math.ceil(HUGE_PROMPT_CHARS / 5) + 10);
  const body = "plan.txt\nzanzibar rollout plan";
  const row = {
    id: "huge-file",
    version: 1,
    at: Date.now(),
    kind: "user",
    text: `${typed}\n${body}`,
    inlineParts: [
      { kind: "text", text: typed },
      { kind: "file", placed: true, name: "plan.txt", mimeType: "text/plain", size: body.length, text: body },
    ],
  } as Row;
  resetTranscriptDisclosure();
  act(() => root.render(<UserBubble row={row} text={row.text ?? ""} />));
  expect(host.querySelector(".cv-user__text")!.classList.contains("is-clamped")).toBe(true);
  expect(host.querySelector("button.cv-user__file-open")).toBeNull();
  act(() =>
    root.render(
      <FindReveal.Provider
        value={{ rowId: row.id, card: false, needle: foldFind("zanzibar rollout plan"), repaint: () => {} }}
      >
        <UserBubble row={row} text={row.text ?? ""} />
      </FindReveal.Provider>,
    ),
  );
  expect(host.querySelector(".cv-user__text")!.classList.contains("is-clamped")).toBe(false);
  expect(host.querySelector("button.cv-user__file-open")?.getAttribute("aria-expanded")).toBe("true");
  expect(host.querySelector(".cv-user__pasted")?.textContent).toContain("zanzibar rollout plan");
});

// A prompt whose recorded parts are only its files (direct.ts keeps them for the band) draws its
// recorded text in the bubble, so Find reads that text. At ac67fede Find read the parts' drawn text,
// which has no file's words, and found nothing of the typed sentence.
test("Find reads a legacy prompt's typed text when its parts are only for its file band", async () => {
  const { findMatches } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const typed = "Please review the quarterly report before Friday";
  const row = {
    id: "legacy-files",
    version: 1,
    at: Date.now(),
    kind: "user",
    text: typed,
    inlineParts: [{ kind: "file", name: "report.pdf", uri: "file:///tmp/report.pdf", mimeType: "application/pdf" }],
  } as Row;
  expect(findMatches([row], "quarterly report")).toEqual([{ rowIndex: 0, rowId: "legacy-files", occurrence: 0 }]);
  const bubble = render(row);
  expect(bubble.textContent).toContain(typed);
  // The file draws in the band above the bubble, not in it.
  expect(bubble.querySelector(".acpmux-file-chip")).toBeNull();
  expect(host.querySelector(".cv-user__files .acpmux-file-chip")).not.toBeNull();
});

// A placed prompt's image the composer left in the strip draws in the band, so the bubble joins the
// words on either side of it as one run; Find reads that same run, not the recorded parts' join.
test("Find reads a placed prompt's words as joined where a strip image left the bubble", async () => {
  const { findMatches } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const inlineParts = [
    { kind: "text", text: "the quick " },
    { kind: "image", id: "strip", mimeType: "image/png", name: "strip.png" },
    { kind: "text", text: "brown fox" },
    { kind: "file", placed: true, name: "notes.txt", mimeType: "text/plain", size: 4, text: "body" },
  ];
  const row = {
    id: "strip-join",
    version: 1,
    at: Date.now(),
    kind: "user",
    text: "the quick \nbrown fox\nbody",
    inlineParts,
  } as Row;
  const bubble = render(row);
  const drawn = bubble.querySelector("[data-inline-content]")!.textContent!;
  expect(drawn).toContain("the quick brown fox");
  expect(findMatches([row], "quick brown")).toEqual([{ rowIndex: 0, rowId: "strip-join", occurrence: 0 }]);
});

// In the strip view every attachment draws in the band, a placed image too, so the bubble joins the
// words on either side of it as one run, and Find reads that run; in the inline view the image
// stands between them, and Find reads them apart. At 38fb9cad Find always read the inline layout,
// and "quick brown" found nothing in the strip view.
test("Find reads a prompt as the active attachment view draws it", async () => {
  const { findMatches, useChatFind } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
  const inlineParts = [
    { kind: "text", text: "the quick " },
    { kind: "image", id: "placed", mimeType: "image/png", name: "placed.png", placed: true },
    { kind: "text", text: "brown fox" },
  ];
  const row = {
    id: "view-join",
    version: 1,
    at: Date.now(),
    kind: "user",
    text: "the quick \nbrown fox",
    inlineParts,
  } as Row;
  const drawn = () => host.querySelector("[data-inline-content]")!.textContent!;
  const found = (view?: "inline" | "strip" | "both") => findMatches([row], "quick brown", view).length;
  try {
    act(() => setComposerSettings({ attachmentView: "strip" }));
    render(row);
    expect(host.querySelector(".cv-user__inline-strip .cv-user__inline-image")).not.toBeNull();
    expect(drawn()).toContain("the quick brown fox");
    expect(found()).toBe(1);
    expect(found("strip")).toBe(1);

    act(() => setComposerSettings({ attachmentView: "inline" }));
    render(row);
    expect(host.querySelector(".cv-user__inline-strip")).toBeNull();
    // The image draws between the two runs, each its own text.
    expect(host.querySelector("[data-inline-content] .cv-user__inline-image")).not.toBeNull();
    expect([...host.querySelectorAll("[data-inline-content] .cv-user__typed")].map((node) => node.textContent)).toEqual(
      ["the quick ", "brown fox"],
    );
    expect(found()).toBe(0);
    expect(found("inline")).toBe(0);
    expect(found("both")).toBe(0);
    // The same row object read in another view is read again, not taken from the cache.
    expect(found("strip")).toBe(1);

    // An open bar finds again when the view changes under it.
    let find: ReturnType<typeof useChatFind> | undefined;
    const Probe = () => {
      find = useChatFind([row]);
      return null;
    };
    act(() => root.render(<Probe />));
    act(() => find!.show("quick brown"));
    expect(find!.matches.length).toBe(0);
    act(() => setComposerSettings({ attachmentView: "strip" }));
    expect(find!.matches.length).toBe(1);
  } finally {
    act(() => setComposerSettings({ attachmentView: "inline" }));
  }
});

test("a sent text file's chip opens to the body it stored, and closes again", () => {
  // Its body went as a text block with no file behind it (no URI), so the chip is the reader's only
  // way to see what was sent, restored messages included.
  const body = "notes.txt\n```\nzanzibar rollout plan\n```";
  const bubble = render({
    id: "file-open",
    version: 1,
    at: Date.now(),
    kind: "user",
    text: `See the notes\n${body}`,
    inlineParts: [
      { kind: "text", text: "See the notes" },
      { kind: "file", placed: true, name: "notes.txt", mimeType: "text/plain", size: 22, text: body },
    ],
  } as Row);
  const opener = bubble.querySelector<HTMLButtonElement>("button.cv-user__file-open");
  expect(opener).not.toBeNull();
  expect(opener!.querySelector(".acpmux-file-chip")?.textContent).toContain("notes.txt");
  expect(opener!.getAttribute("aria-expanded")).toBe("false");
  expect(bubble.textContent).not.toContain("zanzibar rollout plan");
  act(() => opener!.click());
  expect(opener!.getAttribute("aria-expanded")).toBe("true");
  const shown = bubble.querySelector(".cv-user__pasted");
  expect(shown?.textContent).toBe(body);
  // A file's body is no other agent's paste: no "Pasted from" line over it.
  expect(bubble.querySelector(".cv-user__pasted-from")).toBeNull();
  act(() => opener!.click());
  expect(bubble.textContent).not.toContain("zanzibar rollout plan");
});

test("Find matches words across a paste's edge as the bubble draws them, and opens the fold", async () => {
  // Typed "Please check " then a pasted "the upload…": the bubble reads "Please check the upload",
  // so Find must find that, and its match in a collapsed bubble must open it.
  const { findMatches, FindReveal } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const { foldFind } = await import("../src/find/fold");
  const pasted = `the upload ${FIRST} ${SECOND}`;
  const inlineParts = [
    { kind: "text", text: "Please check " },
    { kind: "pasted", placed: true, text: pasted },
  ];
  const row = {
    id: "find-edge",
    version: 1,
    at: Date.now(),
    kind: "user",
    text: `Please check \n${pasted}`,
    inlineParts,
  } as Row;
  expect(findMatches([row], "check the upload").length).toBe(1);
  resetTranscriptDisclosure();
  act(() => root.render(<UserBubble row={row} text={row.text ?? ""} />));
  const text = () => host.querySelector(".cv-user__text")!;
  expect(text().classList.contains("is-clamped")).toBe(true);
  expect(bodies(host.querySelector(".cv-user__bubble")!)[0]!.textContent).toContain("Please check the upload");
  act(() =>
    root.render(
      <FindReveal.Provider
        value={{ rowId: row.id, card: false, needle: foldFind("check the upload"), repaint: () => {} }}
      >
        <UserBubble row={row} text={row.text ?? ""} />
      </FindReveal.Provider>,
    ),
  );
  expect(text().classList.contains("is-clamped")).toBe(false);
});

test("a short message with a paste draws no fold and no card", () => {
  const typed = "Can you look at this?";
  const text = `${typed}\n${THIRD}`;
  const bubble = render({
    id: "short",
    version: 1,
    at: Date.now(),
    kind: "user",
    text,
    pasted: [{ start: typed.length + 1, end: text.length }],
  });
  expect(bubble.querySelectorAll(INNER).length).toBe(0);
  expect(bodies(bubble).length).toBe(1);
  expect(bodies(bubble)[0]!.textContent).toBe(text);
  expect(bubble.querySelectorAll(".cv-user__more").length).toBe(0);
});

// Leo, 2026-11-08: a ChatGPT dictation pasted into the composer, about 1,200 characters of one
// paragraph, showed as "Pasted text · 1.2K characters". The composer sends it as a placed paste
// (pasteMarks.ts); the bubble draws it as the message's own words, with no label, size or control.
test("a 1,200-character dictation paste draws inline in the sent message, no chip or label", () => {
  const dictation = part("dictated", 1_200);
  expect(dictation).not.toContain("\n");
  const typed = "One more thing: ";
  const inlineParts = [
    { kind: "text", text: typed },
    { kind: "pasted", placed: true, name: "Pasted text", text: dictation },
  ];
  const bubble = render({
    id: "dictation",
    version: 1,
    at: Date.now(),
    kind: "user",
    text: `${typed}\n${dictation}`,
    inlineParts,
  } as Row);
  expect(bubble.querySelectorAll(INNER).length).toBe(0);
  expect(bubble.querySelectorAll("[aria-expanded]").length).toBe(0);
  expect(bubble.textContent).not.toContain("Pasted text");
  expect(bubble.textContent).not.toContain("characters");
  const drawn = bodies(bubble);
  expect(drawn.length).toBe(1);
  expect(drawn[0]!.textContent).toBe(`${typed}${dictation}`);
});

afterAll(async () => {
  act(() => root.unmount());
  await teardownDom(saved, { scope });
});
