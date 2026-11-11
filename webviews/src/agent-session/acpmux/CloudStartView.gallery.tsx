// l10n-allow-file: gallery fixtures (a sample prompt, machine names and host words), not shipped UI.
//
// A chat starting in Cloud (CloudStartView.tsx): the person's message, then the start as metadata
// under it (step, folder, machine, secrets, network), never a modal. Compare arms shows the three
// layouts of the `cloud-start-look` experiment.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { cloudStartLook } from "./cloudStart.experiment";
import { CloudStartView } from "./CloudStartView";
import type { CloudStartProgress } from "./cloudStartProgress";

const begun: CloudStartProgress = {
  key: "gallery",
  task: "Run the sidebar tests and fix what fails.",
  state: "starting",
  folder: "paint",
};
const known = { machine: "paint-dev", size: "4 CPU · 16 GB", secrets: 3, network: "limited" } as const;
const timing = { startedAt: 10_000, finishedAt: 12_400 } as const;

const showStart: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cloud-start__summary"));
};

export default componentEntry<ComponentProps<typeof CloudStartView>>({
  id: "agent-pane.cloud-start",
  title: "Cloud start progress",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: ["agent-session/acpmux/CloudStartView.tsx"],
  keywords: ["cloud", "machine", "start", "progress", "secrets", "network"],
  styles: () => Promise.all([import("./styles.css"), import("./conversation/conversation.css")]),
  load: () => import("./CloudStartView").then((module) => module.CloudStartView),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 380,
  variants: {
    sent: {
      note: "Just sent: the message is already in the chat shell with one compact Preparing machine line.",
      props: { start: begun },
    },
    preparing: {
      note: "The shell remains stable while the machine is being prepared; startup details stay behind the disclosure.",
      props: { start: { ...begun, step: "machine", machine: known.machine, size: known.size } },
    },
    machine: {
      note: "The host is getting a machine: the step and the machine with its size.",
      props: { start: { ...begun, step: "machine", machine: known.machine, size: known.size } },
    },
    copying: {
      note: "The folder is copying: every fact known (folder, machine, secrets, a limited network).",
      props: { start: { ...begun, step: "folder", ...known } },
    },
    opening: {
      note: "Last step: the chat opens on the machine, then this tab closes.",
      props: { start: { ...begun, step: "opening", ...known, network: "full" } },
    },
    failed: {
      note: "The start failed: the host's words where the spinner was; the message stays in the composer.",
      props: {
        start: {
          ...begun,
          step: "folder",
          ...known,
          state: "failed",
          message: "Couldn't copy paint to paint-dev: the machine stopped answering.",
        },
      },
    },
    "failed-open": {
      note: "A failed step opens the startup disclosure so the failed row and host details are immediately visible.",
      props: {
        start: {
          ...begun,
          step: "folder",
          ...known,
          state: "failed",
          message: "Couldn't copy paint to paint-dev: the machine stopped answering.",
        },
      },
    },
    "signed-out": {
      note: "The first Cloud send is kept in the composer while the inline sign-in action opens the browser callback.",
      props: {
        start: {
          ...begun,
          state: "failed",
          code: "not_signed_in",
          message: "Sign in to use Cloud.",
        },
        onSignIn: async () => undefined,
      },
    },
    "folder-too-big-repos": {
      note: "A parent of many repositories, too big to copy, refused before any machine: each repository inside it starts the same prompt there, or start with no folder. No Retry.",
      props: {
        start: {
          ...begun,
          folder: "Projects",
          state: "failed",
          code: "cloud_folder_too_big",
          refusedHere: true,
          message:
            "~/Projects is too big to copy to a Cloud machine (at least 20.1 GB in 323,831 files). It holds repositories of its own: pick one to start in, or start without a folder.",
          tooBig: {
            folder: "~/Projects",
            repos: ["cmux", "cmux-platform-docs", "dotfiles", "leo-workspace", "paint", "work/api", "work/web"].map((name) => ({
              name,
              path: `/Users/me/Projects/${name}`,
            })),
            more: false,
          },
        },
        onPickRepo: () => undefined,
        onPickFolder: () => undefined,
        onStartWithoutFolder: () => undefined,
      },
    },
    "folder-too-big-more": {
      note: "More repositories inside than the card lists: Pick a folder joins them.",
      props: {
        start: {
          ...begun,
          folder: "src",
          state: "failed",
          code: "cloud_folder_too_big",
          refusedHere: true,
          message:
            "~/src is too big to copy to a Cloud machine (at least 20 GB in 51,204 files). It holds repositories of its own: pick one to start in, or start without a folder.",
          tooBig: {
            folder: "~/src",
            repos: Array.from({ length: 24 }, (_, index) => ({
              name: `service-${String(index + 1).padStart(2, "0")}`,
              path: `/Users/me/src/service-${index + 1}`,
            })),
            more: true,
          },
        },
        onPickRepo: () => undefined,
        onPickFolder: () => undefined,
        onStartWithoutFolder: () => undefined,
      },
    },
    "folder-too-big-plain": {
      note: "A plain folder too big to copy with no repository inside: the limit, Pick a folder, Start without a folder.",
      props: {
        start: {
          ...begun,
          folder: "Downloads",
          state: "failed",
          code: "cloud_folder_too_big",
          refusedHere: true,
          message:
            "~/Downloads is too big to copy to a Cloud machine (at least 20 GB in 1,204 files; a copy sends at most 20 GB or 500,000 files). Pick a smaller folder, or start without a folder.",
          tooBig: { folder: "~/Downloads", repos: [], more: false },
        },
        onPickFolder: () => undefined,
        onStartWithoutFolder: () => undefined,
      },
    },
    "spend-cap": {
      note: "The team's spending cap refused the machine: an admin can raise it; Run on This Mac sends the same prompt here.",
      props: {
        start: {
          ...begun,
          step: "machine",
          state: "failed",
          code: "cloud_spend_cap",
          message:
            "Your team reached its spending cap, so no Cloud machine can start. A team admin can raise it, or run this chat on this Mac.",
        },
        onRunHere: () => undefined,
        onDismiss: () => undefined,
      },
    },
    "member-budget": {
      note: "The member's own monthly budget refused the machine: an admin can raise it; Run on This Mac goes on here.",
      props: {
        start: {
          ...begun,
          step: "machine",
          state: "failed",
          code: "cloud_member_budget",
          message:
            "You've spent your monthly budget, so no Cloud machine can start. A team admin can raise it, or run this chat on this Mac.",
        },
        onRunHere: () => undefined,
        onDismiss: () => undefined,
      },
    },
    "signing-in": {
      note: "The person clicked Sign in to continue: the card waits on the browser sign-in, not on Cloud.",
      props: { start: { ...begun, signingIn: true } },
    },
    "sign-in-timed-out": {
      note: "The browser sign-in never came back within its limit: the card offers sign in again.",
      props: {
        start: {
          ...begun,
          state: "failed",
          code: "not_signed_in",
          message: "Sign-in timed out. Sign in again to continue.",
        },
        onSignIn: async () => undefined,
      },
    },
    "checklist-machine": {
      note: "Cloud machine is being created; the machine step spins while later steps remain quiet.",
      props: { start: { ...begun, machineStartedAt: 10_000, machine: known.machine } },
    },
    "checklist-clone": {
      note: "A repository is being cloned into the chat folder.",
      props: {
        start: {
          ...begun,
          hasRepository: true,
          repository: "manaflow-ai/cmux",
          machine: known.machine,
          machineFinishedAt: 12_400,
          clone: { state: "running", ...timing },
        },
      },
    },
    "checklist-setup-cached": {
      note: "The environment snapshot is ready, so setup completes from cache.",
      props: {
        start: {
          ...begun,
          hasRepository: true,
          repository: "manaflow-ai/cmux",
          clone: { state: "done", ...timing },
          setup: { state: "done", status: "ready", ...timing },
        },
      },
    },
    "checklist-setup-ran": {
      note: "The setup script ran for this environment, with its install timing shown on the row.",
      props: {
        start: {
          ...begun,
          hasRepository: true,
          repository: "manaflow-ai/cmux",
          clone: { state: "done", ...timing },
          setup: { state: "done", startedAt: 10_000, finishedAt: 12_400 },
        },
      },
    },
    "checklist-setup-running": {
      note: "The derived environment is still building its setup snapshot.",
      props: {
        start: {
          ...begun,
          hasRepository: true,
          repository: "manaflow-ai/cmux",
          clone: { state: "done", ...timing },
          setup: { state: "running", status: "building", startedAt: 10_000 },
        },
      },
    },
    "checklist-setup-failed": {
      note: "Setup failed and the card keeps the short log tail inline.",
      props: {
        start: {
          ...begun,
          hasRepository: true,
          repository: "manaflow-ai/cmux",
          clone: { state: "done", ...timing },
          setup: { state: "failed", status: "failed", logTail: "npm ERR! missing script: build", ...timing },
        },
      },
    },
    "checklist-setup-skipped": {
      note: "No setup script is configured; the link opens Edit cloud environment at Script.",
      props: {
        start: {
          ...begun,
          hasRepository: true,
          repository: "manaflow-ai/cmux",
          clone: { state: "done", ...timing },
          setup: { state: "skipped", hasScript: false },
        },
      },
    },
    "checklist-harness": {
      note: "Last step: the machine, repository and setup are done (checks) and the harness row spins, reading Starting Claude Code until it has (no start time in the fixture: a running row times against the page clock).",
      props: {
        start: {
          ...begun,
          step: "opening",
          agent: "Claude Code",
          hasRepository: true,
          repository: "manaflow-ai/cmux",
          machineStartedAt: 10_000,
          machineFinishedAt: 12_400,
          clone: { state: "done", ...timing },
          setup: { state: "done", ...timing },
        },
      },
    },
    "checklist-harness-failed": {
      note: "The harness failed to start: earlier steps keep their checks, the harness row shows the error mark.",
      props: {
        start: {
          ...begun,
          step: "opening",
          state: "failed",
          agent: "Claude Code",
          hasRepository: true,
          repository: "manaflow-ai/cmux",
          clone: { state: "done", ...timing },
          setup: { state: "done", ...timing },
          message: "Claude Code exited before the session opened.",
        },
      },
    },
    initialized: {
      note: "Once the harness starts, the checklist folds to one quiet line.",
      props: {
        start: {
          ...begun,
          initialized: true,
          agent: "Claude Code",
          harnessStartedAt: 12_400,
          harnessFinishedAt: 12_900,
        },
      },
    },
    ready: {
      note: "The remote harness is ready: the same shell shows a ready line before the live transcript takes over.",
      props: {
        start: {
          ...begun,
          initialized: true,
          agent: "Claude Code",
          harnessStartedAt: 12_400,
          harnessFinishedAt: 12_900,
        },
      },
    },
  },
  // The gallery loads no experiment without a step (format.ts validateEntries): the card is static,
  // so its one step waits for the card the arm draws.
  experiment: { definition: cloudStartLook, script: [{ name: "Show the start", run: showStart }] },
});
