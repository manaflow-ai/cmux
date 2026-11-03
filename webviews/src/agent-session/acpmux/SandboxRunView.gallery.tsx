// l10n-allow-file: gallery fixtures (sample tasks, replies and artifact names), not shipped UI.
//
// A Sandboxed send (hq#3367): the message, the spinner while the throwaway VM runs it, and the
// receipt the chat shows as its result, succeeded and timed out.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import { SandboxRunView } from "./SandboxRunView";

const task = "List the TODOs in this repository and group them by folder.";

export default componentEntry<ComponentProps<typeof SandboxRunView>>({
  id: "agent-pane.sandbox-run",
  title: "Sandboxed run",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: ["agent-session/acpmux/SandboxRunView.tsx"],
  styles: () => Promise.all([import("./styles.css"), import("./conversation/conversation.css")]),
  load: () => import("./SandboxRunView").then((module) => module.SandboxRunView),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 360,
  variants: {
    running: {
      note: "The message, then a turning spinner while the throwaway VM runs it.",
      props: { run: { task, state: "running" } },
    },
    "running-unchecked": {
      note: "A running run whose newest read didn't answer: it stays shown, says so, and offers Check again.",
      props: { run: { task, state: "running" }, unread: true, onCheckAgain: () => undefined },
    },
    succeeded: {
      note: "The receipt: the reply first, then status and exit, time with boot, the VM-time cost, artifacts and VM destroyed.",
      props: {
        run: {
          task,
          state: "done",
          receipt: {
            status: "succeeded",
            exitCode: 0,
            reply: "14 TODOs: web/ 6, cmux-tui/ 5, scripts/ 3. The oldest is in web/services/runs/view.ts.",
            artifacts: [{ name: "todos.md", sizeBytes: 1840 }],
            timings: { totalMs: 96_400, bootMs: 31_200 },
            cost: { vmSeconds: 96, estimateUsd: 0.0029 },
            cleanup: "destroyed",
          },
        },
      },
    },
    "timed-out": {
      note: "A run that hit its limit: the reason, timed out, an unmeasured cost, and the destroy still owed.",
      props: {
        run: {
          task,
          state: "done",
          receipt: {
            status: "failed",
            timedOut: true,
            timings: { totalMs: 612_000, bootMs: null },
            cost: { vmSeconds: null, estimateUsd: null },
            cleanup: "pending",
          },
        },
      },
    },
    refused: {
      note: "The server has not enabled sandboxes for this account: a readable refusal, no VM started.",
      props: { run: { task, state: "failed", code: "run_sandbox_unavailable" } },
    },
  },
});
