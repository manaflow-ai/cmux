// l10n-allow-file: synthetic chat and recap text for the parity workbench.
import { agentPaneEntry } from "../format";
import { minutesAgo } from "../clock";
import { chat } from "../fixtures/acpmux";

export const recapRecording = {
  harness: "claude" as const,
  events: async () =>
    [
      ["user_message", { text: "Make agents open files in the correct workspace." }],
      ["recap", { text: "The goal is to keep files in the right workspace. Next: review the placement change." }],
      ["recap", { text: "The placement change is ready. The review found one duplicate rule. Next: remove it." }],
      [
        "recap",
        {
          text: "The workspace placement fix is ready. A duplicate routing rule is blocking review. Next: choose one PR or split the fix.",
        },
      ],
      [
        "recap",
        {
          text: "Agents now open files in the correct workspace. Review is waiting on one routing fix. Next: split the PR or keep it together.",
        },
      ],
    ]
      .map(([kind, msg], index) =>
        JSON.stringify({
          sessionId: "0190a000-0000-7000-8000-000000000eca",
          seq: index + 1,
          at: minutesAgo(6 - index),
          dir: "mux",
          kind,
          msg,
        }),
      )
      .join("\n"),
};

export default agentPaneEntry({
  id: "agent-pane.parity-away-recap",
  title: "While you were away / compact summary",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/conversation/RecapNote.tsx", "agent-session/acpmux/direct.ts"],
  variants: {
    latest: {
      note: "Four recorded recap updates produce one summary with the latest state in three bullet points.",
      snapshot: chat([], { title: "Workspace placement", harness: "claude", model: "claude-opus-5-5" }),
      recording: recapRecording,
      play: async ({ document, waitFor }) => {
        await waitFor(() => document.querySelector(".cv-recap__points"));
        if (document.querySelectorAll(".cv-recap").length !== 1)
          throw new Error("Recap updates must replace the previous summary");
        if (document.querySelectorAll(".cv-recap__points > li").length !== 3)
          throw new Error("The latest recap must show its three bullet points");
      },
    },
  },
});
