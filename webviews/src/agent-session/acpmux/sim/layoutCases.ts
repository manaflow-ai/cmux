// l10n-allow-file: simulated chat fixtures for the layout-shift case space, not shipped UI.
// The layout-shift case space of the agent chat transcript: every content kind crossed with every way the
// page around it changes while a reply streams, enumerated, so none is left to a person to find. Leo,
// 2026-11-22: "EVERY POSSIBLE CASE, NO MATTER HOW WILD" (with "IF IT NEEDS TO SHIFT, IT SHIFTS ...
// GRACEFULLY ... MATHEMATICALLY, ALL OF THESE SHOULD BE FLAGGABLE").
//
// A case is `content × perturbation`, plus a width sweep with no perturbation. The browser lane
// (test/browser/chat-sim.harness.tsx `runCase`, test/layout-every-case-browser.test.ts) plays each one
// through the real VirtualTranscript with motion on, tracks every row's box on every painted frame with the
// gallery's box tracker (gallery/shift.ts, judged by followJudge.ts) and flags every move over 1 px that
// the reader's own act did not cause. `bun scripts/chat-sim.ts --cases` lists the space.
import { SCENARIOS, longRun } from "./scenarios";
import { sim, type SimScenario } from "./script";

/** What the transcript holds. Each is a short chat whose last turn streams (the moment a perturbation
 *  lands in), so a case runs in seconds. */
export const CONTENT_KINDS = [
  "basic",
  "subagent",
  "compaction",
  "incoming-notice-turn",
  "empty",
  "huge",
  "table",
  "image",
  "mermaid",
  "code-fence",
  "math",
  "rtl",
  "emoji",
  "long-token",
  "list-quote-links",
  "one-word-deltas",
] as const;
export type ContentKind = (typeof CONTENT_KINDS)[number];

/** What happens to the page around the transcript halfway through the streaming turn. `provoked` names
 *  the reader's act that may move boxes (a resize lays every box out once); every other move is a shift. */
export const PERTURBATIONS = {
  none: { provoked: false, about: "nothing: the reply streams, its tools run, the turn ends" },
  resize: { provoked: true, about: "the pane widens (a window resize or a split divider)" },
  "split-narrow": { provoked: true, about: "the pane is split down to a narrow column" },
  zoom: { provoked: true, about: "the page zooms to 125% (Cmd-+)" },
  "font-swap": { provoked: true, about: "the UI font and content size change (a setting)" },
  "theme-swap": { provoked: false, about: "light to dark: colours only, so nothing may move" },
  "scroll-up-parked": { provoked: true, about: "the reader scrolls up into the turn and parks there" },
  "tab-switch": { provoked: true, about: "the reader switches to another chat and back mid-stream" },
  "workspace-switch": { provoked: true, about: "the pane is hidden (another workspace) and shown again" },
  "scroll-burst": { provoked: true, about: "eight wheel flicks up and down, one a frame" },
  "resize-burst": { provoked: true, about: "eight resizes, one a frame (a divider dragged fast)" },
  "reconnect-replay": { provoked: true, about: "the daemon drops; the reconnect replays the whole chat" },
  "duplicate-redelivery": { provoked: false, about: "the same rows delivered again as new objects" },
} as const;
export type Perturbation = keyof typeof PERTURBATIONS;
export const PERTURBATION_NAMES = Object.keys(PERTURBATIONS) as Perturbation[];

/** Pane widths: a narrow split, the default, a wide window. */
export const WIDTHS = [360, 720, 1200] as const;

export type LayoutCase = { id: string; content: ContentKind; perturbation: Perturbation; width: number };

/** Every case: each content kind under each perturbation at the default width, and each content kind at
 *  the other widths with no perturbation. */
export function layoutCases(): LayoutCase[] {
  const cases: LayoutCase[] = [];
  for (const content of CONTENT_KINDS) {
    for (const perturbation of PERTURBATION_NAMES)
      cases.push({ id: `${content}/${perturbation}`, content, perturbation, width: 720 });
    for (const width of WIDTHS)
      if (width !== 720) cases.push({ id: `${content}/none@${width}`, content, perturbation: "none", width });
  }
  return cases;
}

export function layoutCaseById(id: string): LayoutCase {
  const found = layoutCases().find((candidate) => candidate.id === id);
  if (!found) throw new Error(`no layout case ${id}`);
  return found;
}

const PARAGRAPH =
  "I read the retry helper and the test that covers it. The loop allows one attempt too many, so the test that counts calls sees four instead of three. ";
const IMAGE =
  "data:image/svg+xml;utf8," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" width="480" height="270"><rect width="480" height="270" fill="#4a7"/></svg>',
  );

/** The streamed reply of each generated kind: its text arrives in `chunks` deltas, so a block (a table's
 *  rows, a fence) is open across chunk boundaries the way a stream delivers it. */
const REPLY: Partial<Record<ContentKind, { text: string; chunks: number }>> = {
  table: {
    text:
      "Results by package:\n\n| package | tests | time | status |\n|---|---|---|---|\n" +
      Array.from({ length: 12 }, (_, i) => `| packages/p${i} | ${10 + i} | ${(i * 0.37).toFixed(2)}s | pass |`).join(
        "\n",
      ) +
      "\n\nAll green.",
    chunks: 18,
  },
  image: { text: `Here is the chart:\n\n![throughput](${IMAGE})\n\nThe dip is the cold cache.`, chunks: 4 },
  mermaid: {
    text: "The flow:\n\n```mermaid\ngraph TD\n  A[prompt] --> B{tool?}\n  B -->|yes| C[run]\n  C --> B\n  B -->|no| D[reply]\n```\n\nThat is the loop.",
    chunks: 10,
  },
  "code-fence": {
    text:
      "The fix:\n\n````ts\n" +
      Array.from({ length: 24 }, (_, i) => `const step${i} = await retry(() => call(${i}), { attempts: 3 });`).join(
        "\n",
      ) +
      "\n````\n\nThat caps it.",
    chunks: 16,
  },
  math: { text: "The bound:\n\n$$\\sum_{k=0}^{n} 2^k = 2^{n+1} - 1$$\n\nand inline $O(n \\log n)$ holds.", chunks: 6 },
  rtl: {
    text: "النتيجة: الاختبار يمر الآن بعد إصلاح حلقة إعادة المحاولة. שלום, הבדיקה עוברת עכשיו. Mixed: retry ثلاث مرات then stop.",
    chunks: 8,
  },
  emoji: {
    text: "Done ✅🎉 👩🏽‍💻 fixed it 🧪🧪🧪 — flags 🇯🇵🇧🇷🇺🇸, ZWJ 👨‍👩‍👧‍👦, skin tones 👍🏻👍🏿 and more 🔥".repeat(3),
    chunks: 9,
  },
  "long-token": {
    text: `A path with no breaks: ${"a/".repeat(120)}end.ts and a hash ${"f0e1d2c3b4a5".repeat(16)} and https://example.com/${"x".repeat(300)}`,
    chunks: 7,
  },
  "list-quote-links": {
    text: "Steps:\n\n1. Read [the helper](https://example.com/helper)\n2. Fix the loop\n   - nested **bold** item\n   - `code` item\n\n> A quote that is long enough to wrap across more than one line at the default width of the pane.\n\nDone.",
    chunks: 12,
  },
  "one-word-deltas": { text: PARAGRAPH.repeat(3), chunks: 80 },
};

/** The chat a content kind draws, as a scenario. */
export function layoutCaseScenario(content: ContentKind): SimScenario {
  if (content === "empty")
    return sim("layout-empty", "An empty chat: one prompt, a turn that ends with nothing drawn.")
      .prompt("Hello?")
      .turnEnd()
      .build();
  if (content === "huge") {
    const long = longRun(80);
    return { ...long, name: "layout-huge", about: "80 turns of history, then the last turn streams" };
  }
  if (content === "subagent")
    return sim("layout-subagent", "A turn that runs a subagent while the reply streams.")
      .prompt("Search the repo for the retry helper.")
      .think("Starting a subagent for the search.")
      .subagent("Find every caller of retry()", { ms: 3_000, report: "Found 4 callers." })
      .say(PARAGRAPH, { chunks: 6 })
      .tool("bun test api/client.test.ts")
      .say("Fixed.")
      .turnEnd()
      .build();
  if (content === "compaction")
    return sim("layout-compaction", "A turn that compacts the context mid-stream.")
      .prompt("Keep going on the refactor.")
      .tool("rg -n retry src")
      .compaction()
      .say(PARAGRAPH, { chunks: 6 })
      .turnEnd()
      .build();
  const reply = REPLY[content];
  if (reply)
    return sim(`layout-${content}`, `A turn whose reply streams ${content}.`)
      .prompt("Show me what you found.")
      .think("Collecting it.")
      .tool("rg -n retry src", { ms: 400 })
      .say(reply.text, { chunks: reply.chunks, chunkMs: 60 })
      .tool("bun test", { ms: 300 })
      .say("That is all.", { chunks: 2 })
      .turnEnd()
      .build();
  const named = SCENARIOS[content];
  if (!named) throw new Error(`no content kind ${content}`);
  return named();
}

/** A flag: one box that moved more than `FLAG_PX` with no act of the reader's to explain it. */
export type LayoutFlag = { step: number; label: string; kind: string; px: number };
export type LayoutCaseResult = {
  id: string;
  steps: number;
  frames: number;
  flags: LayoutFlag[];
  worst: number;
  error?: string;
};

/** A move larger than this is a shift (Leo's ">1px": layout rounding is under it). */
export const FLAG_PX = 1;
