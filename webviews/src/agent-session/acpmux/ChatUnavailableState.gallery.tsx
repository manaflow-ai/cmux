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
    deleted: {
      note: "Deletion is explicit; saved transcript recovery remains available.",
      props: { ...base, unavailable: { reason: "machineDeleted", machine: "Demo machine" } },
    },
  },
});
