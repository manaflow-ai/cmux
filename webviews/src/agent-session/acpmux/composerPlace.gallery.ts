// l10n-allow-file: gallery fixtures (sample chats and prompts), not shipped UI.
// The composer outside the transcript's scroller (composerPlace.experiment.ts; cmuxterm-hq
// docs/design/agent-transcript-clean-slate.md: "The composer is outside the scroller. Its growth
// shrinks the viewport. When pinned, the bottom edge holds. When not pinned, the top anchor holds.").
// A chat long enough to scroll, at its bottom or scrolled up, with a one-line or five-line draft, in
// each arm. test/composer-outside-scroller.test.ts types the draft and samples every frame.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";
import { composerPlace, type ComposerPlace } from "./composerPlace.experiment";
import { COMPOSER_MD_FIELD } from "./composerSelectors";

const turns = (count = 24) =>
  Array.from({ length: count }, (_, index) => [
    user(`Question ${index + 1}: how does the retry helper back off?`, 600 - index * 20),
    assistant(
      `Answer ${index + 1}. The helper waits a jittered backoff between tries, only for network errors and 5xx answers, and gives up after three attempts. A 404 never retries.`,
      590 - index * 20,
    ),
  ]).flat();

const ONE_LINE = { draft: "Also cover the 503 path" };
const FIVE_LINES = { draft: "First line of the plan\nsecond line\nthird line\nfourth line\nfifth line" };
const arm = (place: ComposerPlace) => ({ experiments: { [composerPlace.id]: place } });
const scrolledUp: Play = async (ctx) => {
  await ctx.scroll({ selector: ".acpmux-scroll" }, 600);
};
const grow: Play = async (ctx) => {
  await ctx.focus({ selector: `${COMPOSER_MD_FIELD} .ProseMirror` });
  for (let line = 2; line <= 5; line++) {
    await ctx.press("Shift+Enter");
    await ctx.type(`line ${line} of the draft`);
  }
};

export default agentPaneEntry({
  id: "agent-pane.composer-outside-scroller",
  title: "Composer outside the transcript's scroller",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 420, normal: 700, wide: 900 },
  covers: [
    "agent-session/acpmux/composerPlace.experiment.ts",
    "agent-session/acpmux/bottomStack.css",
    "agent-session/acpmux/VirtualTranscript.tsx",
  ],
  keywords: ["composer", "scroller", "viewport", "pinned", "anchor", "grow", "clean slate"],
  experiment: { definition: composerPlace, script: [{ name: "Grow the draft to five lines", run: grow }] },
  variants: {
    "outside-bottom-one-line": {
      note: "Outside the scroller, at the bottom with a one-line draft: the last message sits on the viewport's bottom edge, right above the composer.",
      snapshot: chat(turns()),
      ready: ONE_LINE,
      ...arm("outside"),
    },
    "outside-bottom-five-lines": {
      note: "Outside the scroller, at the bottom with a five-line draft: the viewport is shorter and the last message still sits on its bottom edge.",
      snapshot: chat(turns()),
      ready: FIVE_LINES,
      ...arm("outside"),
    },
    "outside-scrolled-up-five-lines": {
      note: "Outside the scroller, scrolled up with a five-line draft: the reader's top row holds as the composer grows or shrinks.",
      snapshot: chat(turns()),
      ready: FIVE_LINES,
      play: scrolledUp,
      ...arm("outside"),
    },
    "over-bottom-one-line": {
      note: "Today (ships): the stack over the transcript's foot, at the bottom with a one-line draft.",
      snapshot: chat(turns()),
      ready: ONE_LINE,
      ...arm("over"),
    },
    "over-bottom-five-lines": {
      note: "Today (ships): the stack over the transcript's foot, at the bottom with a five-line draft.",
      snapshot: chat(turns()),
      ready: FIVE_LINES,
      ...arm("over"),
    },
  },
});
