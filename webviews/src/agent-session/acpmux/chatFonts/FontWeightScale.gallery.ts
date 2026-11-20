// l10n-allow-file: synthetic gallery conversation, not shipped UI.
// A font pack's weights and reply size (chatDisplay.ts UI_WEIGHT_KEY, PROSE_WEIGHT_KEY,
// PROSE_SCALE_KEY). A pack copies a reference look in a face whose stroke and x-height differ, so it
// sets the interface weight, the reply prose's weight, and the reply prose's size as a share of the
// chat's. Leo, 2026-11-18: "for claude there's the font and the nested sessions and whatever". The
// Claude look (cmux#46705) is its sans at 430 with replies at 1.095, which puts the lowercase at the
// reference's 0.540 em x-height. The sans here is a stand-in with the same 0.493 em x-height: the
// font study's Hanken Grotesk under the font pack gallery's made-up name, Folio Sans (OFL).
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, CWD, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import {
  CHAT_FONT_FACES_KEY,
  PROSE_FAMILY_KEY,
  PROSE_SCALE_KEY,
  PROSE_WEIGHT_KEY,
  UI_FAMILY_KEY,
  UI_WEIGHT_KEY,
} from "../chatDisplay";
import type { Play } from "../../../gallery/play";
import { FOLIO_PACK, packLoaded } from "./FontPack.gallery";
import folioSans from "../../../gallery/fontStudy/fonts/hanken-grotesk.woff2?inline";

/// The sans alone, for the interface and the replies.
const SANS: Record<string, unknown> = {
  [UI_FAMILY_KEY]: "Folio Sans",
  [PROSE_FAMILY_KEY]: "Folio Sans",
  [CHAT_FONT_FACES_KEY]: { "Folio Sans": folioSans },
};

/// The Claude look's values: 430 everywhere, replies at 1.095 (0.493 em x 1.095 = 0.540 em).
export const CLAUDE_LIKE: Record<string, unknown> = { ...SANS, [UI_WEIGHT_KEY]: 430, [PROSE_SCALE_KEY]: 1.095 };

/// The sans's face loads after the display push: the stage waits for it, so no capture shows the fallback.
const sansLoaded: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.fonts.check('15px "Folio Sans"') && ctx.document.fonts.status === "loaded");
};

const transcript = chat([
  user("Why does the retry test fail on CI but pass locally?", 6),
  assistant(
    "I'll compare the test with the helper. The assertion may run before the retry delay ends, which only shows on a loaded runner.",
    5,
  ),
  activity(
    [
      tool("bun test src/fetch/retry.test.ts", "execute", "completed", { output: "12 tests passed" }),
      tool("rg -n sleep src/fetch", "execute", "completed", { output: "src/fetch/retry.ts:4" }),
    ],
    5,
  ),
  assistant(
    [
      "### What happened",
      "",
      "The test used **real timers**, so on a loaded runner the third attempt landed *after* the assertion. `retry()` now takes the `sleep` it waits with, and the test passes a fake one.",
      "",
      "- Backoff is 200, 400 and 800 ms.",
      "- A retried `POST` sends the same idempotency key.",
      "",
      "All 12 tests pass, three times in a row.",
    ].join("\n"),
    4,
  ),
  summary(4, { status: "completed", toolCount: 2, durationMs: 32_000 }),
]);

const DRAFT = "Open the PR and keep the timer change in its own commit.";

const variant = (note: string, display: Record<string, unknown>, play?: Play): AgentPaneVariant => ({
  note,
  snapshot: transcript,
  ready: { cwd: CWD, draft: DRAFT },
  display,
  ...(play && { play }),
});

export default agentPaneEntry({
  id: "agent-pane.font-weight-scale",
  title: "Font pack weights and reply text scale",
  area: "Agent pane",
  height: 760,
  widths: { narrow: 420, normal: 640, wide: 760 },
  covers: ["agent-session/acpmux/chatDisplay.ts", "agent-session/acpmux/conversation/conversation.css"],
  keywords: ["font", "font pack", "weight", "scale", "x-height", "typography", "claude", "theme"],
  variants: {
    default: variant("The default chat: no pack, no weight, no scale.", {}),
    "sans-plain": variant(
      "The stand-in sans at its normal weight and the chat's size: its 0.493 em x-height reads small and light.",
      SANS,
      sansLoaded,
    ),
    "claude-like": variant(
      "The Claude look: the sans at 430, replies at 1.095, so the lowercase sits at the reference's 0.540 em. Prompts, code, the tool rows and the composer keep their sizes.",
      CLAUDE_LIKE,
      sansLoaded,
    ),
    "serif-scaled": variant(
      "The Folio pack's serif replies at 1.15 and weight 450: its small 0.426 em x-height brought up to the sans around it.",
      { ...FOLIO_PACK, [PROSE_WEIGHT_KEY]: 450, [PROSE_SCALE_KEY]: 1.15 },
      packLoaded,
    ),
  },
});
