// l10n-allow-file: gallery fixtures (subagent names and tasks), not shipped UI.
// Retry on a subagent's end line (SubagentDoneLine.tsx, retryState.ts), for Leo's two rows that
// died on a transient capacity error (2026-10-26: "this needs to retry :("). While acpmux waits to
// retry, the line reads "Retrying (2/4) after a capacity error" with the turning ring, never a dot.
// A failed line offers Retry once, on hover: on the line, or only in its ⋯ menu, never both; one
// acpmux gave up on says how many tries it had; a Task subagent acpmux cannot retry offers the same
// "Retry", which asks the chat's agent. A subagent the harness refused to start is one quiet line
// with nothing to click. Three places for the failed line's Retry are compared: an inline button
// (the pick), a link after the line, and the ⋯ menu alone. Synthetic data.
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import type { RetryAffordance } from "./subagentDoneLineModel";
import type { Subagent } from "./subagentFold";
import { failedLineLook } from "./failedLine.experiment";

/** `base`: the line as the base draws it, with no Retry wired. */
type Props = { lines: Subagent[]; affordance?: RetryAffordance; base?: boolean };

const agent = (name: string, task: string, fields: Partial<Subagent> = {}): Subagent => ({
  id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
  parent: null,
  name,
  task,
  kind: "general-purpose",
  state: "failed",
  startedAt: minutesAgo(40),
  endedAt: minutesAgo(16),
  prompt: task,
  ...fields,
});

const overview = (fields: Partial<Subagent> = {}) =>
  agent("Remote acpmux setup overview", "Remote acpmux setup overview for Lawrence", {
    endedAt: minutesAgo(40 - 12.05),
    ...fields,
  });
const relay = (fields: Partial<Subagent> = {}) =>
  agent("Push relay", "Push relay for GCP lane bundles", { endedAt: minutesAgo(40 - 23.75), ...fields });

const capacity = { reason: "capacity", nextAt: Date.now() + 60_000 };
const error = "503: no non-exhausted claude accounts available";
const FAILED = [overview({ retryable: true, error }), relay({ retryable: true, error })];

/// Leo's three failed lines (2026-11-03: "this ui is pretty awkward looking"): long tasks and one
/// long API error, as the transcript drew them, all in red with Retry floating after the words.
const API_ERROR =
  "Agent terminated early due to an API error. The request timed out after 600s; retry with a smaller context.";
const THREE = [
  agent("Fix reply button", "Fix white-on-white reply button in the composer menu", {
    retryable: true,
    error: API_ERROR,
    endedAt: minutesAgo(40 - 20.03),
  }),
  agent("Cloud transport", "Diagnose Cloud chat transport refusal on resume", {
    retryable: true,
    error: API_ERROR,
    endedAt: minutesAgo(40 - 24.43),
  }),
  agent("Folder sync", "Speed up Cloud folder sync", {
    retryable: true,
    error: API_ERROR,
    endedAt: minutesAgo(40 - 21.95),
  }),
];
/// Leo's row (2026-11-11: "this is kind of weird tbh"): a subagent Claude Code refused to start, 13ms
/// after the Agent call, on its concurrent subagent limit. The parent's own failed tool call.
const REFUSAL =
  "Concurrent subagent limit reached. You can run 40 subagents at once. Do not retry. If the user wants more concurrent subagents, ask them to increase CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS.";
const refused = (name: string, fields: Partial<Subagent> = {}) =>
  agent(name, name, { startedAt: minutesAgo(20), endedAt: minutesAgo(20) + 13, error: REFUSAL, ...fields });
const REFUSED = [refused("Why only some messages are forked")];

const MIXED = [
  THREE[0]!,
  overview({ retryable: true, retry: { attempt: 2, of: 4, ...capacity } }),
  agent("Docs pass", "Tighten the running tray spec", { state: "completed", endedAt: minutesAgo(30) }),
  relay({ retryable: true, retriedOut: { attempt: 4, of: 4, reason: "capacity" }, error }),
];

/** The ⋯ menu opens on the click (menus never fade in). */
const openMenu: Play = async (ctx) => {
  await ctx.click({ selector: '[data-menu="subagent-done"]' });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]') !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.subagent-retry",
  title: "Subagent retry",
  area: "Agent pane",
  pane: true,
  height: 200,
  widths: { narrow: 420, normal: 720, wide: 900 },
  covers: [
    "agent-session/acpmux/subagents/SubagentDoneLine.tsx",
    "agent-session/acpmux/subagents/failedLine.experiment.ts",
  ],
  experiment: { definition: failedLineLook, script: [{ name: "Leo's three failed lines", run: async () => {} }] },
  load: async () => {
    const { SubagentDoneLine } = await import("./SubagentDoneLine");
    const { RetryAffordanceContext } = await import("./subagentDoneLineModel");
    const { TurnActionsContext } = await import("../conversation/turnActions");
    const { SUBAGENT_DONE } = await import("./subagentRows");
    const restartSubagent = () => {};
    const actions = { retryAgent: async () => undefined, restartSubagent };
    return function GallerySubagentRetry({ lines, affordance = "button", base }: Props) {
      const rows: AcpmuxRow[] = lines.map((line, index) => ({
        id: `done-${index}`,
        version: 1,
        kind: SUBAGENT_DONE,
        at: line.endedAt ?? Date.now(),
        subagents: [line],
      }));
      return (
        <div className="acpmux-shell" style={{ padding: "16px", flexDirection: "column", gap: "4px" }}>
          <TurnActionsContext.Provider value={base ? { restartSubagent } : actions}>
            <RetryAffordanceContext.Provider value={affordance}>
              {rows.map((row) => (
                <div key={row.id}>
                  <SubagentDoneLine row={row} />
                </div>
              ))}
            </RetryAffordanceContext.Provider>
          </TurnActionsContext.Provider>
        </div>
      );
    };
  },
  styles: () =>
    Promise.all([import("../styles.css"), import("../conversation/conversation.css"), import("./subagents.css")]),
  variants: {
    "leo-three-failed": {
      note: 'Leo\'s three failed lines (2026-11-03: "this ui is pretty awkward looking"). The pick: one quiet grid, mark | title | short reason | Retry | time on the same columns on every line, the title in plain text, red only on the mark.',
      props: { lines: THREE },
    },
    "mixed-states": {
      note: "A failed line, a retrying one, a finished one and one acpmux gave up on: only the failed lines take the grid; Retry and the time line up between them.",
      props: { lines: MIXED },
    },
    "grid-long-cells": {
      note: "The grid's growing cells: Retry on a subagent acpmux cannot retry, and a run past an hour. Retry and the time grow instead of spilling into the next column.",
      props: {
        lines: [
          THREE[0]!,
          agent("Task worker", "Rebuild the nightly signing picker", {
            error: API_ERROR,
            endedAt: minutesAgo(40 - 20.5),
          }),
          agent("Long soak", "Soak the pause and resume path for an hour", {
            retryable: true,
            error: API_ERROR,
            startedAt: minutesAgo(130),
            endedAt: minutesAgo(40),
          }),
        ],
      },
    },
    before: {
      note: "Before: Leo's two rows as the base draws them, the failure in the danger color and no way to run them again but Restart on hover.",
      props: { lines: [overview({ retryable: true }), relay({ retryable: true })], base: true },
    },
    "failed-capacity": {
      note: "The pick. A failed line acpmux can retry: Retry as a small quiet button in its column, shown on hover; no ⋯ menu repeating it and no Restart beside it.",
      props: { lines: FAILED, affordance: "button" },
    },
    "failed-link": {
      note: "Version B: Retry as a link after the line's time. Quieter, but reads as part of the sentence.",
      props: { lines: FAILED, affordance: "link" },
    },
    "failed-menu-only": {
      note: "Version C: Retry only in the ⋯ menu, opened here. Nothing new at rest, but a failure gives no visible way out.",
      props: { lines: FAILED, affordance: "menu" },
      play: openMenu,
    },
    "menu-open": {
      note: "The ⋯ menu exists only where the line has no Retry of its own (the menu affordance): opened, its one Retry.",
      props: { lines: [overview({ retryable: true })], affordance: "menu" },
      play: openMenu,
    },
    "refused-spawn": {
      note: "Leo's row (2026-11-11: \"this is kind of weird tbh\"): a subagent the harness refused to start. It is the parent's own failed tool call: its name and the harness's one short reason, no Retry, no Restart, no menu, no time.",
      props: { lines: REFUSED },
    },
    "refused-hover": {
      note: "The refused row under the pointer: nothing appears, as nothing on it acts.",
      props: { lines: REFUSED },
    },
    "refused-among-lines": {
      note: "A refused row beside a failed run, a finished one and another refusal: only the run that failed offers Retry (on hover), and the refused rows stay one quiet line each.",
      props: {
        lines: [
          REFUSED[0]!,
          THREE[0]!,
          agent("Docs pass", "Tighten the running tray spec", { state: "completed", endedAt: minutesAgo(30) }),
          refused("Audit the transcript chrome", { retryable: true }),
        ],
      },
    },
    retrying: {
      note: "acpmux waits to retry: the turning ring and 'Retrying (2/4) after a capacity error'; no Retry while it waits.",
      props: {
        lines: [
          overview({ retryable: true, retry: { attempt: 2, of: 4, ...capacity } }),
          relay({ retryable: true, retry: { attempt: 1, of: 4, ...capacity } }),
        ],
      },
    },
    "retried-out": {
      note: "acpmux gave up after its last try: the line says so, and Retry runs it once more.",
      props: { lines: [relay({ retryable: true, retriedOut: { attempt: 4, of: 4, reason: "capacity" } })] },
    },
    "task-ask-parent": {
      note: "A Task subagent acpmux cannot retry (no `retryable`): the same Retry, which sends the chat one line naming the task and its description.",
      props: { lines: [relay()] },
    },
  },
});
