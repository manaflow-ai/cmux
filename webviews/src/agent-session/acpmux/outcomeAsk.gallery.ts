// l10n-allow-file: gallery sample asks and interaction labels, not shipped UI.
import { agentPaneEntry } from "../../gallery/format";
import { noChat } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import { COMPOSER_EDITOR } from "./composerSelectors";
import { outcomeAsk } from "./outcomeAsk.experiment";

const ASK = "Fix the parser";
const OUTCOME = "The parser tests pass and existing inputs still work.";
const FIELD = ".acpmux-outcome-ask textarea";
const ready = { transport: "mock", newSession: true, sandboxState: true, cwd: "~/code/app" };

async function typeAsk(ctx: PlayContext) {
  await ctx.waitFor(() => ctx.document.querySelector(COMPOSER_EDITOR), { capMs: 10_000 });
  await ctx.type(ASK, { selector: COMPOSER_EDITOR });
}

export default agentPaneEntry({
  id: "agent-pane.outcome-ask",
  title: "Outcome-shaped ask",
  area: "Agent pane",
  experimental: true,
  height: 560,
  widths: { narrow: 400, normal: 760, wide: 1040 },
  covers: ["agent-session/acpmux/Composer.tsx#Composer", "agent-session/acpmux/outcomeAsk.ts"],
  variants: {
    off: {
      note: "Default: the existing composer has no extra field.",
      snapshot: noChat([]),
      ready,
      experiments: { [outcomeAsk.id]: "off" },
      play: typeAsk,
    },
    empty: {
      note: "Opt-in: Done when is optional; an empty field leaves the sent ask unchanged.",
      snapshot: noChat([]),
      ready,
      experiments: { [outcomeAsk.id]: "on" },
      play: typeAsk,
    },
    filled: {
      note: "Opt-in: a checkable outcome accompanies the short ask.",
      snapshot: noChat([]),
      ready,
      experiments: { [outcomeAsk.id]: "on" },
      play: async (ctx) => {
        await typeAsk(ctx);
        await ctx.type(OUTCOME, { selector: FIELD });
      },
    },
  },
  experiment: {
    definition: outcomeAsk,
    script: [
      { name: "Write a short ask", run: typeAsk },
      {
        name: "Add the optional outcome",
        run: async (ctx) => {
          if (ctx.document.querySelector(FIELD)) await ctx.type(OUTCOME, { selector: FIELD });
        },
      },
      {
        name: "Send the ask",
        run: async (ctx) => {
          await ctx.focus({ selector: COMPOSER_EDITOR });
          await ctx.press("Enter");
        },
      },
    ],
  },
});
