// l10n-allow-file: public-safe gallery fixtures, not shipped copy.
import { componentEntry } from "../../gallery/format";
import type { ComponentProps } from "react";
import type { ChatUnavailableState } from "./ChatUnavailableState";
const base = {
  machine: "Demo machine",
  session: "example-chat-001",
  onRemove() {},
  onReconnect() {},
  onResume() {},
  onClose() {},
  onResumeMachine() {},
  // The settled look; `paused-quick` shows the first 1.5 s (afterDelay.ts).
  noteDelayMs: 0,
};
export default componentEntry<ComponentProps<typeof ChatUnavailableState>>({
  id: "agent-pane.cloud-chat-recovery",
  title: "Cloud chat recovery",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/ChatUnavailableState.tsx#ChatUnavailableState"],
  styles: () => import("./styles.css"),
  load: () => import("./ChatUnavailableState").then((m) => m.ChatUnavailableState),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 420,
  variants: {
    before: {
      note: "Before: paused and deleted machines both offered Reconnect.",
      props: { ...base, unavailable: { reason: "offline", machine: "Demo machine" } },
    },
    paused: {
      note: "Selected: same quiet card, with the precise Resume machine action.",
      props: { ...base, unavailable: { reason: "paused", machine: "Demo machine" } },
    },
    resuming: {
      note: "The action stays visible but disabled while resuming.",
      props: {
        ...base,
        unavailable: { reason: "paused", machine: "Demo machine" },
        resuming: true,
      },
    },
    "paused-quick": {
      note: "Paused for under 1.5 s (the machine may already be waking): nothing, in the loading layout, so a quick wake never flashes a card.",
      props: { ...base, noteDelayMs: 3_600_000, unavailable: { reason: "paused", machine: "Demo machine" } },
    },
    "slow-resume": {
      note: "Resuming past 1.5 s: the spinner fades into its slot; nothing else moves.",
      props: {
        ...base,
        unavailable: { reason: "paused", machine: "Demo machine" },
        resuming: true,
      },
    },
    "resume-failed": {
      note: "The resume ran out: one plain line says so, Resume machine is back, and the card stays calm.",
      props: {
        ...base,
        unavailable: { reason: "paused", machine: "Demo machine" },
        error: "The machine did not reconnect. Try resuming it again.",
      },
    },
    deleted: {
      note: "Deletion is explicit; saved transcript recovery remains available.",
      props: { ...base, unavailable: { reason: "machineDeleted", machine: "Demo machine" } },
    },
  },
});
