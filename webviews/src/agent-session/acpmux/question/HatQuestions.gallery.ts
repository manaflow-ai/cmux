// l10n-allow-file: gallery fixtures, not shipped UI.
// The agent's questions in the composer hat (HatQuestions.tsx) over a stand-in composer: three wait,
// the pager steps through them, a click answers one, and a typed reply withdraws the chat's own
// question. Three arms (hatQuestions.experiment.ts; view Compare arms): the band (shipped), one line,
// a chip that opens into the band. Leo, 2026-11-07: "the composer hat can become a dual thing where
// you can go through it and, like, click left and right through things and be able to answer things
// as they come".
// Its × (Leo, 2026-11-11: "there's no close button :("): three ways to show it, all with Escape.
// Shipped: on hover, in a room it keeps at rest (dismiss-hover). Compared: always shown
// (dismiss-always), and over the band's corner in no room of its own (dismiss-corner), which covers
// the pager and is why the × keeps a room.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { hatQuestionsLook } from "./hatQuestions.experiment";

type Props = {
  count?: number;
  look?: "band" | "line" | "chip";
  dismissLook?: "hover" | "always" | "corner";
  first?: "child";
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
    name: "the × puts the shown question away",
    run: async (ctx: PlayContext) => {
      const before = prompt(ctx);
      await ctx.click({ selector: ".acpmux-hat-questions__dismiss" });
      await ctx.waitFor(() => prompt(ctx) !== before);
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

export default componentEntry<Props>({
  id: "agent-pane.hat-questions",
  title: "Composer hat: the agent's questions",
  area: "Agent pane",
  covers: ["agent-session/acpmux/question/HatQuestions.tsx"],
  load: () => import("../../../gallery/fixtures/HatQuestionsStage").then((module) => module.HatQuestionsStage),
  pane: true,
  height: 300,
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
    "dismiss-hover": {
      note: "Shipped: a started chat's question, its name on a line of its own and the question under it, and the × at the head's end, faded in on hover or focus in a room it keeps at rest, so nothing moves. Escape puts it away too.",
      props: { first: "child" },
    },
    "dismiss-always": {
      note: "The × always shown, in the same room: findable at a glance, one more mark at rest.",
      props: { first: "child", dismissLook: "always" },
    },
    "dismiss-corner": {
      note: "The × over the band's top corner, in no room of its own: it sits on the pager and the text runs under it. Rejected.",
      props: { first: "child", dismissLook: "corner" },
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
