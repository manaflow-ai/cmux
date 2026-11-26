// l10n-allow-file: gallery fixtures (prompts, subagent names), not shipped UI.
// A subagent composer's model and mode (SubagentForkChips.tsx, subagentForkChips.experiment.ts).
// Leo, 2026-11-22 08:07Z: "so for subagents, actually, are their permissions/model locked right then
// and there? does it make sense to be able to reveal the fork or whatever switching model behaviour
// for it?" and 08:23Z, on a mode chip that read "follows parent": "why not a greyed out permission
// situation and then the HOVER shows that?"
//
// A running subagent's model is fixed at its start; a Claude subagent's permissions follow its chat's
// live mode, a Codex one's were copied at its start. So the chips can only tell the truth, and the one
// honest way to run it otherwise is to fork its context into a chat of the person's own. Three looks:
// - `off` (the default, as before): no chips;
// - `chips` (A, the pick): the chat's chips greyed, the hover says why, a click opens
//   Fork with <model>… / Fork with <mode>…;
// - `takeover` (B): one Take over in new chat… button whose menu picks a model and a mode, then forks;
// - `hover` (C): A's chips, shown only while the pointer or focus is on the composer.
// Each look: a running and a finished subagent, of a Claude chat and of a Codex chat. Compare them at
// 420 and 900 px and in light, dark and glass (the gallery's colorScheme and background).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo, recentRun } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxSnapshot } from "../model";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { subagentForkChipsLook } from "./subagentForkChips.experiment";

type Arm = keyof typeof subagentForkChipsLook.arms;
type Harness = "claude" | "codex";
const pins = (arm: Arm) => ({ "subagent-fork-chips": arm });
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

const MODES: Record<Harness, NonNullable<NonNullable<AcpmuxSnapshot["summary"]>["modes"]>> = {
  claude: {
    currentModeId: "bypassPermissions",
    availableModes: [
      { id: "auto", name: "Auto" },
      { id: "default", name: "Manual" },
      { id: "acceptEdits", name: "Accept edits" },
      { id: "plan", name: "Plan" },
      { id: "bypassPermissions", name: "Bypass permissions" },
    ],
  },
  codex: {
    currentModeId: "agent",
    availableModes: [
      { id: "agent", name: "agent" },
      { id: "auto-review", name: "auto-review" },
      { id: "agent-full-access", name: "agent-full-access" },
    ],
  },
};

function snapshot(harness: Harness, state: Subagent["state"], canForkSubagent = true): AcpmuxSnapshot {
  const base = chat(
    [
      user("Audit the fetch helper: retries, errors, timeouts and tests", 4),
      row(SUBAGENTS, 3.8, {
        subagents: [
          agent("Retry policy", 3.8, "completed"),
          agent("Test coverage", 3.8, state, {
            ...(state === "running" ? { action: "bun test src/net" } : {}),
            agentId: "a39e817af38ddf5e7",
            // A Claude Agent call that asked for Sonnet: the chip names it, not the chat's Opus.
            ...(harness === "claude" ? { spawnModel: "claude-sonnet-5-5" } : {}),
          }),
        ],
      }),
    ],
    {
      isWorking: state === "running",
      harness,
      model: harness === "claude" ? "claude-opus-5-5" : "gpt-6-astra",
      ...(canForkSubagent ? { canForkSubagent: true as const } : {}),
    },
  );
  return {
    ...base,
    summary: { ...base.summary!, modes: MODES[harness] },
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
}

/** Opens the pane on the subagent, as the app's `subagent:` reveal does. */
async function openSubagent(ctx: PlayContext) {
  const page = ctx.document.defaultView as unknown as { cmuxAcpmuxBridge?: { revealTurn?(id: string): void } };
  page.cmuxAcpmuxBridge?.revealTurn?.(`subagent:${COVERAGE}`);
  await ctx.waitFor(() => ctx.document.querySelector("[data-composer-relay]"));
}

/** The look's chips, drawn in the relayed composer, never the chat's pickers. */
const shows = (arm: Arm) => async (ctx: PlayContext) => {
  await openSubagent(ctx);
  if (arm === "off") {
    if (ctx.document.querySelector("[data-subagent-chips]")) throw new Error("the off arm drew subagent chips");
    return;
  }
  await ctx.waitFor(() => ctx.document.querySelector(`[data-subagent-chips="${arm}"]`));
  if (ctx.document.querySelector("[data-composer-relay] .acpmux-access-trigger"))
    throw new Error("the subagent's composer drew the chat's mode picker");
};

const menuOpen = (arm: Arm, chip: "model" | "mode") => async (ctx: PlayContext) => {
  await shows(arm)(ctx);
  const selector =
    arm === "takeover" ? '[data-subagent-chips="takeover"] button' : `[data-subagent-chip="${chip}"] button`;
  await ctx.click({ selector });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-subagent-fork-menu"));
};

const hovered = async (ctx: PlayContext) => {
  await shows("hover")(ctx);
  await ctx.hover({ selector: "[data-composer-relay]" });
};

const variant = (arm: Arm, harness: Harness, state: Subagent["state"], note: string, play = shows(arm)) => ({
  note,
  snapshot: snapshot(harness, state),
  experiments: pins(arm),
  play,
});

export default agentPaneEntry({
  id: "agent-pane.subagent-fork-chips",
  title: "Subagent composer: model, mode and fork",
  area: "Agent pane",
  height: 640,
  anchors: [{ selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentForkChips.tsx",
    "agent-session/acpmux/subagents/subagentForkChips.css",
    "agent-session/acpmux/subagents/subagentForkChips.experiment.ts",
  ],
  keywords: ["subagent", "composer", "fork", "model", "mode", "permissions", "read-only"],
  experiment: {
    definition: subagentForkChipsLook,
    script: [{ name: "the subagent's pane", run: (ctx) => shows(subagentForkChipsLook.defaultArm)(ctx) }],
  },
  variants: {
    "off-claude-running": variant(
      "off",
      "claude",
      "running",
      "Off (the default, as before): no chips on the subagent's composer.",
    ),
    "off-codex-done": variant("off", "codex", "completed", "Off, Codex, finished: no chips."),
    "a-claude-running": variant(
      "chips",
      "claude",
      "running",
      "A, Claude, running: Sonnet 5.5 (its Agent call asked for it) and Bypass permissions, greyed. Hover the mode: it follows the chat.",
    ),
    "a-claude-done": variant(
      "chips",
      "claude",
      "completed",
      "A, Claude, finished: the same chips; a fork still carries its context.",
    ),
    "a-codex-running": variant(
      "chips",
      "codex",
      "running",
      "A, Codex, running: the chat's GPT-6-Astra and Ask for approval, both copied at its spawn.",
    ),
    "a-codex-done": variant("chips", "codex", "completed", "A, Codex, finished."),
    "a-model-menu": variant(
      "chips",
      "claude",
      "running",
      "A, the model chip clicked: why it is fixed, then Fork with <model>… for each model.",
      menuOpen("chips", "model"),
    ),
    "a-mode-menu": variant(
      "chips",
      "claude",
      "running",
      "A, the mode chip clicked: it follows the chat, then Fork with <mode>… (Plan is no start mode).",
      menuOpen("chips", "mode"),
    ),
    "a-no-capability": {
      note: "A, an acpmux without acp.session.fork.subagent.v1: the same greyed chips, no chevron and no menu.",
      snapshot: snapshot("claude", "running", false),
      experiments: pins("chips"),
      play: shows("chips"),
    },
    "b-claude-running": variant(
      "takeover",
      "claude",
      "running",
      "B, Claude, running: one Take over in new chat… button.",
    ),
    "b-codex-done": variant("takeover", "codex", "completed", "B, Codex, finished."),
    "b-menu": variant(
      "takeover",
      "claude",
      "running",
      "B, open: a model and a mode to pick, then Fork into new chat.",
      menuOpen("takeover", "model"),
    ),
    "c-claude-running": variant(
      "hover",
      "claude",
      "running",
      "C, Claude, running, pointer away: the chips keep their room, hidden.",
    ),
    "c-claude-hover": variant("hover", "claude", "running", "C, the pointer on the composer: A's chips show.", hovered),
    "c-codex-done": variant("hover", "codex", "completed", "C, Codex, finished, pointer on the composer.", hovered),
  },
});
