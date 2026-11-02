// l10n-allow-file: gallery fixtures (subagent names and tasks), not shipped UI.
// Retry on a subagent's end line (SubagentDoneLine.tsx, retryState.ts), for Leo's two rows that
// died on a transient capacity error (2026-10-26: "this needs to retry :("). While acpmux waits to
// retry, the line reads "Retrying (2/4) after a capacity error" with the turning ring, never a dot.
// A failed line offers Retry, inline and in its ⋯ menu (shown on hover); one acpmux gave up on says
// how many tries it had; a Task subagent acpmux cannot retry offers "Ask parent to retry". Three
// places for the failed line's Retry are compared: an inline button (the pick), a link after the
// line, and the ⋯ menu alone. Synthetic data.
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import type { RetryAffordance } from "./SubagentDoneLine";
import type { Subagent } from "./subagentFold";

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
  covers: ["agent-session/acpmux/subagents/SubagentDoneLine.tsx"],
  load: async () => {
    const { SubagentDoneLine, RetryAffordanceContext } = await import("./SubagentDoneLine");
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
    before: {
      note: "Before: Leo's two rows as the base draws them, the failure in the danger color and no way to run them again but Restart on hover.",
      props: { lines: [overview({ retryable: true }), relay({ retryable: true })], base: true },
    },
    "failed-capacity": {
      note: "The pick. A failed line acpmux can retry: Retry as a small outlined button right after it, always shown; its ⋯ menu (on hover) has Retry and Ask parent to retry.",
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
      note: "The pick's ⋯ menu, opened: Retry (acpmux) and Ask parent to retry.",
      props: { lines: [overview({ retryable: true })], affordance: "button" },
      play: openMenu,
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
      note: "A Task subagent acpmux cannot retry (no `retryable`): Ask parent to retry, which sends the chat one line naming the task and its description.",
      props: { lines: [relay()] },
    },
  },
});
