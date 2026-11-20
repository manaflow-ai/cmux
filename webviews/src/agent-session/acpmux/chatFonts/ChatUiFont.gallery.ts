// l10n-allow-file: synthetic gallery conversation, not shipped UI.
// The chat's interface font candidates side by side (chatUiFont.ts, `agentPane.display.font.ui`): the
// same transcript and composer in each face. Leo, 2026-11-05: "Because right now it's just Apple
// System, right? ... I mean, there's the Reddit slash Hacker News Verdana font, which I'm generally
// fond of. And then, I don't know, I think Roboto is generally okay as well. And then Inter with some
// variation, like modification, is kind of good." Linux has no Verdana: its capture draws DejaVu Sans,
// the stand-in the stack names, so judge Verdana in the app.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import { BUNDLED_FAMILY, CHAT_UI_FONT_KEY, CHAT_UI_FONTS, type ChatUiFont, DEFAULT_CHAT_UI_FONT } from "../chatUiFont";

const snapshot = chat([
  user("Why does the retry test fail on CI but pass locally?", 3),
  activity(
    [
      thought("The assertion may run before the retry delay ends. Compare the test with the helper."),
      tool("Read src/fetch/retry.ts", "read", "completed"),
      tool("bun test src/fetch/retry.test.ts", "execute", "completed", { output: "12 tests passed" }),
    ],
    2.6,
  ),
  assistant(
    [
      "The test used **real timers**, so on a loaded CI runner the third attempt landed after the assertion.",
      "",
      "- `retry()` now takes a `sleep` it can be given, and the test passes fake timers.",
      "- Backoff is 200 ms, 400 ms, 800 ms; the jitter stays within ±10%.",
      "",
      "All 12 tests pass, 3 times in a row (0.4 s each).",
    ].join("\n"),
    2,
  ),
  summary(2, { status: "completed", toolCount: 2, durationMs: 32_000 }),
]);

const NOTES: Record<ChatUiFont, string> = {
  "inter-tuned": "cmux Inter: Inter with the calculated tracking the app used until 2026-11-07, bundled (Latin).",
  inter: "Stock Inter at its designed spacing, bundled (Latin).",
  verdana: "Verdana, Hacker News's and old Reddit's face (macOS has it). Linux draws DejaVu Sans in its place.",
  roboto: "Roboto, bundled (Latin).",
  plex: "IBM Plex Sans, bundled (Latin).",
  "source-sans": "Source Sans 3, bundled (Latin).",
  geist: "Geist, bundled (Latin).",
  "cmux-sans": "cmux Sans, ours: Source Sans 3 with an 8 % taller lowercase, bundled (Latin).",
  hanken: "Hanken Grotesk, a warm grotesque, bundled (Latin).",
  atkinson: "Atkinson Hyperlegible Next, built for legibility, bundled (Latin).",
  "system-ui": "The default: the system font (SF Pro on macOS) at its own spacing. Linux draws its own sans.",
  "system-ui-tight": "The system font a step tighter, more at the larger sizes.",
};

/// A bundled face loads behind a dynamic import after the display push: the stage waits for it, so
/// no capture shows the fallback.
const faceLoaded =
  (family: string): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.fonts.check(`14px "${family}"`) && ctx.document.fonts.status === "loaded");
  };

export default agentPaneEntry({
  id: "agent-pane.chat-ui-font",
  title: "Chat interface font candidates",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 420, normal: 640, wide: 760 },
  covers: ["agent-session/acpmux/chatUiFont.ts", "agent-session/acpmux/chatFonts/faces.ts"],
  keywords: ["font", "typeface", "typography", "verdana", "roboto", "inter", "plex", "geist", "source sans"],
  variants: Object.fromEntries(
    CHAT_UI_FONTS.map((font) => [
      font,
      {
        note: NOTES[font],
        snapshot,
        display: font === DEFAULT_CHAT_UI_FONT ? {} : { [CHAT_UI_FONT_KEY]: font },
        ...(font in BUNDLED_FAMILY && { play: faceLoaded(BUNDLED_FAMILY[font as keyof typeof BUNDLED_FAMILY]) }),
      },
    ]),
  ),
});
