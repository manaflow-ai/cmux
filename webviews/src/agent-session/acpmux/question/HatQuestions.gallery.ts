// l10n-allow-file: gallery fixtures, not shipped UI.
// The agent's questions in the composer hat (HatQuestions.tsx) over a stand-in composer: three wait,
// the pager steps through them, a click answers one, and a typed reply withdraws the chat's own
// question. Three arms (hatQuestions.experiment.ts; view Compare arms): the band (shipped), one line,
// a chip that opens into the band. Leo, 2026-11-07: "the composer hat can become a dual thing where
// you can go through it and, like, click left and right through things and be able to answer things
// as they come".
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { hatQuestionsLook } from "./hatQuestions.experiment";

type Props = {
  count?: number;
  look?: "band" | "line" | "chip";
  child?: boolean;
  replyLook?: "below" | "inline" | "reveal";
  refuse?: boolean;
};

const prompt = (ctx: PlayContext) => ctx.document.querySelector(".acpmux-hat-questions__prompt")?.textContent ?? "";
const position = (ctx: PlayContext) => ctx.document.querySelector(".acpmux-hat-questions__position")?.textContent ?? "";

export const hatQuestionsScript = [
  {
    name: "three questions wait: the hat shows the first, 1 of 3",
    run: async (ctx: PlayContext) => {
      await ctx.waitFor(() => position(ctx).startsWith("1"));
    },
  },
  {
    name: "right steps to the tagged ask",
    run: async (ctx: PlayContext) => {
      await ctx.click({ selector: '.acpmux-hat-questions__step:not([data-step="previous"])' });
      await ctx.waitFor(() => prompt(ctx).startsWith("Can you create"));
    },
  },
  {
    name: "a click on Yes answers it, and the hat shows what is left",
    run: async (ctx: PlayContext) => {
      await ctx.click({ selector: ".acpmux-hat-questions__answer" });
      await ctx.waitFor(() => !prompt(ctx).startsWith("Can you create"));
    },
  },
  {
    name: "a reply typed in the composer withdraws the chat's own question",
    run: async (ctx: PlayContext) => {
      await ctx.type("Use passkeys, and keep API keys for the CLI", { selector: "[data-stage-composer]" });
      await ctx.press("Enter");
      await ctx.waitFor(() => !prompt(ctx).startsWith("Which auth"));
    },
  },
];

// A started chat's question answered in the hat (Leo, 2026-11-10: "this is unusable to respond to i
// necessarily have to open... this is bad ui"): More shows the whole question, then a typed answer
// goes with Send and the question leaves.
const childPlay = async (ctx: PlayContext) => {
  await ctx.click({ selector: ".acpmux-hat-questions__more" });
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-hat-questions__prompt[data-whole]")));
  const reveal = ctx.document.querySelector(".acpmux-hat-questions__reply") === null;
  if (reveal) await ctx.click({ selector: ".acpmux-hat-questions__quiet" });
  await ctx.type("Remove the older one only", { selector: ".acpmux-hat-questions__field" });
  await ctx.click({ selector: ".acpmux-hat-questions__send" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-hat-questions__prompt") === null);
};

export default componentEntry<Props>({
  id: "agent-pane.hat-questions",
  title: "Composer hat: the agent's questions",
  area: "Agent pane",
  covers: ["agent-session/acpmux/question/HatQuestions.tsx"],
  load: () => import("../../../gallery/fixtures/HatQuestionsStage").then((module) => module.HatQuestionsStage),
  pane: true,
  // Tall enough for the dock (`.acpmux-dock` max-height leaves the transcript 140 px) to hold the
  // band whole: at 300 the band was clipped under the composer.
  height: 520,
  experiment: { definition: hatQuestionsLook, script: hatQuestionsScript },
  variants: {
    one: {
      note: "One question: the yellow mark, its tag, the question, its answers as buttons and Type an answer. No pager.",
      props: { count: 1 },
    },
    three: {
      note: "Three wait: the pager reads 1 of 3, and left and right step through them.",
      props: {},
    },
    line: {
      note: "The one-line arm: the question cut to the room left, its answers at the line's end.",
      props: { look: "line" },
    },
    chip: {
      note: "The chip arm, folded: the yellow mark and 1 of 3, centred over the composer.",
      props: { look: "chip" },
    },
    "started-chat": {
      note: "Picked. A started chat's question answered in place: who asks and what about on the first line, the whole question under it (two lines, then More), its choices with the recommended one marked, and a reply field with Send on its own line under them. Open Chat stays for the rest.",
      props: { child: true, replyLook: "below" },
    },
    "started-chat-inline": {
      note: "The reply field at the end of the choices' line: one line shorter, but the field gets what the choices leave, and wraps under them on a narrow pane.",
      props: { child: true, replyLook: "inline" },
    },
    "started-chat-reveal": {
      note: "The reply field behind a quiet Reply button: the shortest band, one more click to type an answer.",
      props: { child: true, replyLook: "reveal" },
    },
    "started-chat-refused": {
      note: "The host refused the answer (another computer's chat, a click too old): the band says so and takes input again.",
      props: { child: true, replyLook: "below", refuse: true },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-hat-questions__answer" });
        await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-hat-questions__failed")));
      },
    },
    "started-chat-play": {
      note: "More shows the whole question; a typed answer goes with Send, and the question leaves the hat.",
      props: { child: true, replyLook: "below" },
      play: childPlay,
    },
    play: {
      note: "Step to the tagged ask, answer it with a click, then type a reply that withdraws the chat's own question.",
      props: {},
      play: async (ctx) => {
        for (const step of hatQuestionsScript) await step.run(ctx);
      },
    },
  },
});
