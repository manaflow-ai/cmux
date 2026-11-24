// l10n-allow-file: gallery fixtures (sample chats, prompts and replies), not shipped UI.
// cmux Sans's personalities on the chat: the font study's screen (FontStudy.gallery.ts: a long reply
// with code, a table, CJK and emoji, and the composer) in the system font, Folio's sans (Hanken
// Grotesk, the reference for "squat"), cmux Sans, and its Squat,
// and Candy cuts. Leo, 2026-11-19: cmux Sans looks "a bit like generic school font ... It just
// doesn't have that like pizzazz"; he likes squat faces. Pick one here. With the sidebar, open a
// variant in the mock app:
//   mock-app.html?fixture=font-study.sans-personality/squat&colorScheme=light
// Side by side: the compare view (`view=compare`), one cell per font. Settings in each font:
// pages.settings-sans-personality.
import { agentPaneEntry, type AgentPaneVariant } from "../format";
import type { Play } from "../play";
import { fontStudySnapshot } from "./FontStudy.gallery";
import { applyArmFont, SANS_PERSONALITIES, SANS_PERSONALITY_NAMES, sansPersonality } from "./sansPersonality";

export default agentPaneEntry({
  id: "font-study.sans-personality",
  title: "cmux Sans personality",
  area: "Agent pane",
  covers: ["gallery/fontStudy/sansPersonality.ts", "gallery/fontStudy/candidates.ts"],
  keywords: ["font", "typeface", "typography", "cmux sans", "hanken", "squat", "candy", "open", "sidebar"],
  variants: Object.fromEntries(
    SANS_PERSONALITY_NAMES.map((name): [string, AgentPaneVariant] => [
      name,
      { note: SANS_PERSONALITIES[name].note, snapshot: fontStudySnapshot, fontStudy: SANS_PERSONALITIES[name].pairing },
    ]),
  ),
  experiment: {
    definition: sansPersonality,
    setup: applyArmFont,
    script: [
      {
        name: "scroll to the table",
        run: (async (ctx) => {
          await ctx.scroll({ selector: ".acpmux-scroll" }, "bottom");
        }) satisfies Play,
      },
    ],
  },
});
