// l10n-allow-file: gallery fixtures (sample chat names), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { ManagedBanner } from "./ManagedBanner";

type Props = Parameters<typeof ManagedBanner>[0];

const onHide = () => undefined;
const onOpenManager = () => undefined;

export default componentEntry<Props>({
  id: "agent-pane.managed-banner",
  title: "A chat the Chief or another agent runs",
  area: "Agent pane",
  height: 120,
  covers: ["agent-session/acpmux/ManagedBanner.tsx#ManagedBanner"],
  pane: true,
  load: () => import("./ManagedBanner").then((module) => module.ManagedBanner),
  variants: {
    chief: {
      props: { manager: { kind: "chief" }, onHide },
      note: "A Chief's subagent: Chief is sending messages here, Hide",
    },
    agent: {
      props: {
        manager: { kind: "agent", name: "claude-sr2-coord", sessionId: "s-coord" },
        onHide,
        onOpenManager,
      },
      note: "A sub-session another chat started: its name opens that chat",
    },
    "long-name": {
      props: {
        manager: {
          kind: "agent",
          name: "Land the group chat guest composer and approvals across Home and New Tab",
          sessionId: "s-long",
        },
        onHide,
        onOpenManager,
      },
      note: "A long chat title is cut with an ellipsis; Hide keeps its size",
    },
  },
});
