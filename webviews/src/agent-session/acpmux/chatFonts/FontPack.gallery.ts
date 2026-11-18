// l10n-allow-file: synthetic gallery conversation, not shipped UI.
// A font pack, off and on (chatDisplay.ts, chatFontFaces.ts): a community typography theme from the
// app store sets the chat's interface family (`font.uiFamily`), the agent's reply prose family
// (`font.proseFamily`), the code family, the text size and line height, and brings its faces as data
// URLs (`font.faces`), since the pane's CSP takes fonts only from data:. Leo, 2026-11-18: "would be
// maybe weird to bundle into the main app... but would be neato as one of our offshot thingys that ppl
// can apply thru our app store thing". The pack here, Folio, is the
// font study's files under made-up names (gallery/fontStudy/fonts, OFL): Hanken Grotesk as Folio
// Sans, Newsreader as Folio Serif, JetBrains Mono as Folio Mono. Off is the default chat.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, CWD, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import { CHAT_FONT_FACES_KEY, PROSE_FAMILY_KEY, UI_FAMILY_KEY } from "../chatDisplay";
import folioSans from "../../../gallery/fontStudy/fonts/hanken-grotesk.woff2?inline";
import folioMono from "../../../gallery/fontStudy/fonts/jetbrains-mono.woff2?inline";
import folioSerif from "../../../gallery/fontStudy/fonts/newsreader.woff2?inline";

/// The pack's `display` keys, as the host would push them once it is applied.
export const FOLIO_PACK: Record<string, unknown> = {
  [UI_FAMILY_KEY]: "Folio Sans",
  [PROSE_FAMILY_KEY]: "Folio Serif",
  "agentPane.display.code.family": "Folio Mono",
  "agentPane.display.font.size": 15,
  "agentPane.display.font.lineHeight": 1.6,
  // Folio Mono's x-height is far above Folio Serif's: at 0.8 of the text size its lowercase sits level
  // with the serif's.
  "agentPane.display.code.scale": 0.8,
  [CHAT_FONT_FACES_KEY]: { "Folio Sans": folioSans, "Folio Serif": folioSerif, "Folio Mono": folioMono },
};

const transcript = chat([
  user("Why does the retry test fail on CI but pass locally?", 14),
  activity(
    [
      thought("The assertion may run before the retry delay ends. Compare the test with the helper."),
      tool("Read src/fetch/retry.ts", "read", "completed"),
      tool("bun test src/fetch/retry.test.ts", "execute", "completed", { output: "12 tests passed" }),
    ],
    13,
  ),
  assistant(
    [
      "## What happened",
      "",
      "The test used **real timers**, so on a loaded CI runner the third attempt landed *after* the assertion. Locally the machine is idle, the delays finish in time, and the race never shows.",
      "",
      "- `retry()` now takes a `sleep` it can be given, and the test passes fake timers.",
      "- Backoff is 200 ms, 400 ms, 800 ms; the jitter stays within ±10%.",
      "- The helper keeps `fetch` idempotent: a retried `POST` sends the same key.",
      "",
      "```ts",
      "const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms));",
      "export async function retry<T>(run: () => Promise<T>, wait = sleep): Promise<T> {",
      "  for (let attempt = 0; ; attempt++) {",
      "    try { return await run(); } catch (error) { if (attempt === 2) throw error; }",
      "    await wait(200 * 2 ** attempt);",
      "  }",
      "}",
      "```",
      "",
      "All 12 tests pass, 3 times in a row (0.4 s each).",
    ].join("\n"),
    12,
  ),
  summary(12, { status: "completed", toolCount: 2, durationMs: 32_000 }),
  user("Can you also check the upload path? It retries on its own.", 6),
  activity([tool("Read src/upload/queue.ts", "read", "completed")], 5),
  assistant(
    [
      "The upload queue has its own loop, and it **never backs off**: a failed chunk is sent again at once, up to five times. Two changes:",
      "",
      "1. The queue calls the shared `retry()`, so uploads wait 200, 400 and 800 ms like everything else.",
      "2. A chunk that fails with a 4xx is not retried at all; only timeouts and 5xx are.",
      "",
      "> The old loop could send the same 8 MB chunk five times in under a second on a flaky network.",
      "",
      "I left the chunk size alone. Want me to open the PR?",
    ].join("\n"),
    4,
  ),
  summary(4, { status: "completed", toolCount: 1, durationMs: 18_000 }),
]);

/// A reply with everything prose carries (headings, inline code, bold, italic, a fenced block, a
/// list, a table), shown from its top: the stage is tall enough for all of it.
export const RICH_REPLY = [
  "## Why the retry test flakes",
  "",
  "The test used **real timers**, so on a loaded runner the third attempt landed *after* the assertion. Locally the machine is idle and `retry()` finishes in time, so the race never shows.",
  "",
  "### The fix",
  "",
  "`retry()` now takes the `sleep` it waits with, and the test passes a fake one. The backoff and the error it gives up with are *unchanged*:",
  "",
  "```ts",
  "const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms));",
  "",
  "export async function retry<T>(run: () => Promise<T>, wait = sleep): Promise<T> {",
  "  for (let attempt = 0; ; attempt++) {",
  "    try {",
  "      return await run();",
  "    } catch (error) {",
  "      if (attempt === 2) throw error;",
  "    }",
  "    await wait(200 * 2 ** attempt);",
  "  }",
  "}",
  "```",
  "",
  "- Backoff is 200, 400 and 800 ms; the jitter stays within 10%.",
  "- A retried `POST` sends the same idempotency key.",
  "- The upload queue calls the shared `retry()` too.",
  "",
  "| Run | Real timers | Fake timers |",
  "| --- | --- | --- |",
  "| Local | 12 / 12 | 12 / 12 |",
  "| CI | 9 / 12 | 12 / 12 |",
  "",
  "All 12 tests pass, three times in a row.",
].join("\n");

export const richChat = chat([
  user("Why does the retry test fail on CI but pass locally?", 3),
  assistant(RICH_REPLY, 2),
  summary(2, { status: "completed", toolCount: 2, durationMs: 32_000 }),
]);

const DRAFT = "Yes, open it. Keep the **4xx** rule in its own commit and name `retry()` in the title.";

/// The pack's faces load after the display push: the stage waits for them, so no capture shows the
/// fallback.
export const packLoaded: Play = async (ctx) => {
  await ctx.waitFor(
    () =>
      ["Folio Sans", "Folio Serif", "Folio Mono"].every((family) => ctx.document.fonts.check(`15px "${family}"`)) &&
      ctx.document.fonts.status === "loaded",
  );
};

/// The rich reply alone, from its top, pack off or on.
const real = (pack: boolean): AgentPaneVariant => ({
  note: `${pack ? "Font pack on" : "Font pack off"}: one reply with headings, inline code, a code block, a list and a table, from its top.`,
  snapshot: richChat,
  ready: { cwd: CWD },
  display: pack ? FOLIO_PACK : {},
  height: 1150,
  ...(pack && { play: packLoaded }),
});

const variant = (pack: boolean, composer: boolean): AgentPaneVariant => ({
  note: `${pack ? "Font pack on: Folio Sans chrome, Folio Serif replies, Folio Mono code, 15px on 1.6" : "Font pack off: the default chat"}${composer ? ", the composer with a draft" : ", a long transcript"}.`,
  snapshot: composer ? chat([assistant("Want me to open the PR?", 1)]) : transcript,
  ready: { cwd: CWD, draft: DRAFT },
  display: pack ? FOLIO_PACK : {},
  ...(composer && { height: 320 }),
  ...(pack && { play: packLoaded }),
});

export default agentPaneEntry({
  id: "agent-pane.font-pack",
  title: "Font pack: a community typography theme, off and on",
  area: "Agent pane",
  height: 760,
  widths: { narrow: 420, normal: 640, wide: 760 },
  covers: ["agent-session/acpmux/chatFontFaces.ts", "agent-session/acpmux/chatDisplay.ts"],
  keywords: ["font", "font pack", "typography", "theme", "serif", "prose", "faces", "app store"],
  variants: {
    off: variant(false, false),
    on: variant(true, false),
    "composer-off": variant(false, true),
    "composer-on": variant(true, true),
    "real-off": real(false),
    "real-on": real(true),
  },
});
