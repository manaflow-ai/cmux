// l10n-allow-file: reproduction of the user's stacked-material screenshot.
import { agentPaneEntry } from "../format";
import { GALLERY_NOW, minutesAgo } from "../clock";
import { activity, assistant, chat, row, session, SESSION_ID, summary, tool, user } from "../fixtures/acpmux";
import type { AcpmuxSnapshot } from "../../agent-session/acpmux/model";
import { SUBAGENTS, type Subagent } from "../../agent-session/acpmux/subagents/subagentFold";

export const STACK_QUESTION =
  'Your "Yes": reply `I restarted it` or `I did not restart it` if my reading (you restarted the laptop) is wrong.';
const ended: Subagent[] = ["opt-out-daemon-2", "claude-22/opt-merge-queue", "opt-out-review"].map((name, index) => ({
  id: `stack-material-agent-${index}`,
  parent: null,
  name,
  state: "completed",
  startedAt: minutesAgo(30 - index),
  endedAt: GALLERY_NOW - (40 - index * 10) * 1000,
}));
const base = chat(
  [
    user("Optimize cmux-tui and acpmux for speed and correctness and land the changes.", 60),
    assistant("I am checking the restart behavior while the background sessions continue.", 12),
    activity(
      [tool("mcp__acpmux__wrap_up", "other", "completed", { inputSummary: JSON.stringify({ ask: STACK_QUESTION }) })],
      12,
    ),
    summary(12, { status: "completed" }),
    row("user", 10, {
      text: "The background checks are still running.",
      untyped: true,
      incoming: {
        kind: "message",
        message: {
          name: "opt-out-host-3",
          text: "The background checks are still running.",
          raw: "The background checks are still running.",
        },
      },
    }),
    row(SUBAGENTS, 9, { subagents: ended }),
    assistant("The two sessions are still checking. The restart question remains open.", 8),
    summary(8, { status: "completed" }),
  ],
  { title: "Stacked surfaces / screenshot reproduction", isWorking: false },
);

export const stackMaterialsSnapshot: AcpmuxSnapshot = {
  ...base,
  summary: {
    ...base.summary!,
    goal: {
      objective: "Optimize cmux-tui and acpmux for speed and correctness and land the changes",
      status: "running",
      provider: "claude",
      startedAt: GALLERY_NOW - (58 * 3600 + 11 * 60 + 49) * 1000,
      updatedAt: minutesAgo(8),
    },
  },
  sessions: [
    ...base.sessions,
    ...["claude-22/opt-c-survive", "opt-out-host-3"].map((title, index) =>
      session({
        sessionId: `stack-material-session-${index}`,
        title,
        spawnedBy: SESSION_ID,
        startedBy: SESSION_ID,
        indicator: "working",
        status: "running",
        lane: "working",
        createdAt: minutesAgo(7 - index),
      }),
    ),
  ],
};

export default agentPaneEntry({
  id: "agent-pane.parity-stack-materials",
  title: "Stacked surfaces / screenshot reproduction",
  area: "Agent pane",
  height: 660,
  widths: { narrow: 420, normal: 920, wide: 1100 },
  covers: ["agent-session/acpmux/composerStates.css", "agent-session/acpmux/bottomStack.css"],
  variants: {
    screenshot: {
      note: "The screenshot's pinned restart ask, running goal, duplicate question hat, two running sessions, three done agents, and composer together. The gallery uses a bundled backdrop.",
      snapshot: stackMaterialsSnapshot,
      play: async ({ document, waitFor, click }) => {
        for (const selector of [
          ".acpmux-pending-ask .acpmux-next-step",
          ".acpmux-goal[data-look]",
          ".acpmux-hat-questions__body",
          ".acpmux-running-tray__head",
          ".acpmux-composer-box",
        ])
          await waitFor(() => document.querySelector(selector));
        const head = document.querySelector(".acpmux-running-tray__head")!;
        if (head.getAttribute("aria-expanded") !== "true") await click({ selector: ".acpmux-running-tray__head" });
        await waitFor(() => document.querySelectorAll(".acpmux-running-tray .acpmux-agent-line").length === 5);
      },
    },
  },
});
