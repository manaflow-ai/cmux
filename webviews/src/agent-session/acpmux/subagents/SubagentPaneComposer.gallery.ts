// l10n-allow-file: gallery fixtures (prompts, subagent names), not shipped UI.
// A subagent's own pane ends in the chat's own Composer, relayed to the subagent (Composer.tsx
// `relay`, App.tsx `subagentRelay`): the same box, at the same place and size as a chat's, with its
// hat when the hat has content (Leo 2026-11-22: "the subagent their composer area needs to be good
// too tho... i notice there's differing layouts among it and normal chats... we should align things
// better"). What acts on the chat's own turn is off there: no Stop, queue, model or mode chips, +
// menu, context ring or line under the box. `chat` is the normal chat the other two are drawn
// against: their box is its box, to the pixel.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo, recentRun } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";

const COVERAGE = "agent-test-coverage";

function agent(name: string, minutes: number, state: Subagent["state"], fields: Partial<Subagent> = {}): Subagent {
  return {
    id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
    parent: null,
    name,
    task: name,
    state,
    ...(state === "running" ? { startedAt: minutesAgo(minutes) } : recentRun(minutes, 1.5)),
    ...fields,
  };
}

const AUDIT = chat(
  [
    user("Audit the fetch helper: retries, errors, timeouts and tests", 4),
    row(SUBAGENTS, 3.8, {
      subagents: [
        agent("Retry policy", 3.8, "completed"),
        agent("Timeouts", 3.8, "running", { action: "Read src/net/timeouts.ts" }),
        agent("Test coverage", 3.8, "running", { action: "bun test src/net", agentId: "a39e817af38ddf5e7" }),
      ],
    }),
  ],
  { isWorking: true },
);

const SNAPSHOT: typeof AUDIT = {
  ...AUDIT,
  subagentViews: {
    [COVERAGE]: [
      activity(
        [
          thought("Which tests cover retries and timeouts today?"),
          tool("Read src/net/fetch.test.ts", "read", "completed"),
        ],
        3.6,
        { id: `${COVERAGE}:activity-1` },
      ),
      assistant("Retries have no tests. Splitting unit and integration coverage.", 3.3, {
        id: `${COVERAGE}:assistant-2`,
      }),
    ],
  },
};

/** The composer's form and box, as a test and a reader compare them with the chat's. */
function composerBox(ctx: PlayContext) {
  const forms = ctx.document.querySelectorAll(".acpmux-composer");
  if (forms.length !== 1) throw new Error(`the pane drew ${forms.length} composers`);
  const form = forms[0]!;
  if (form.getAttribute("data-cmux-component") !== "Composer")
    throw new Error(`the composer is ${form.getAttribute("data-cmux-component")}, not the chat's Composer`);
  return form;
}

/** Opens the pane on the subagent, as the app's `subagent:` reveal does, and checks its composer is
 * the chat's Composer relayed to it, with none of the chat's turn controls. */
const openSubagent = (hat: boolean) => async (ctx: PlayContext) => {
  const page = ctx.document.defaultView as unknown as { cmuxAcpmuxBridge?: { revealTurn?(id: string): void } };
  page.cmuxAcpmuxBridge?.revealTurn?.(`subagent:${COVERAGE}`);
  await ctx.waitFor(
    () => !ctx.document.querySelector(".cv-subagent-of") && ctx.document.querySelector("[data-composer-relay]"),
  );
  const form = composerBox(ctx);
  const field = form.querySelector('[role="combobox"]');
  if (field?.getAttribute("aria-label") !== "Message Test coverage")
    throw new Error(`the subagent's composer names ${field?.getAttribute("aria-label")}`);
  if (ctx.document.querySelector(".cv-subagent-composer-via")) throw new Error("a line under the box names the chat");
  if (form.querySelector(".acpmux-cancel")) throw new Error("the subagent's composer offers the chat's Stop");
  if (hat) await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray"));
};

export default agentPaneEntry({
  id: "agent-pane.subagent-composer",
  title: "Subagent pane composer",
  area: "Agent pane",
  height: 640,
  anchors: [{ selector: ".acpmux-composer" }],
  covers: ["agent-session/acpmux/Composer.tsx#Composer"],
  keywords: ["subagent", "composer", "relay", "hat", "layout"],
  variants: {
    chat: {
      note: "The normal chat the subagent's pane is drawn against: its composer box, with the hat of running subagents over it.",
      snapshot: SNAPSHOT,
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer"));
        if (composerBox(ctx).hasAttribute("data-composer-relay")) throw new Error("the chat's composer is a relay");
      },
    },
    "subagent-hat": {
      note: "The subagent's own pane with the hat on: the same Composer and box as the chat's, \"Message Test coverage\", the hat over it.",
      snapshot: SNAPSHOT,
      play: openSubagent(true),
    },
    subagent: {
      note: "The subagent's own pane before the hat draws: the same box at the same place as the chat's.",
      snapshot: SNAPSHOT,
      play: openSubagent(false),
    },
  },
});
