// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a pasted cmux link (a workspace, tab or chat link) draws once cmux knows what it names (Leo,
/// 2026-11-08: "it should be able to render in the box that it is an actual chat that is there,
/// like with the title and whatever"). Every arm keeps the link's own text in the message and the
/// draft; only its look changes. Gallery `agent-pane.cmux-link-chips`.
export const cmuxLinkLook = defineExperiment({
  id: "cmux-link-look",
  title: "Pasted cmux links",
  description:
    "How a cmux://workspace/…, cmux://agent/… or cmux.com/deeplink/agent link reads in a sent message and the draft once its target is known.",
  arms: {
    "icon-title-host": {
      label: "Icon, title, machine",
      description:
        "The session chip's wash with the kind's icon and the title; a chat or workspace on another machine adds the machine, muted.",
    },
    "icon-title": {
      label: "Icon and title",
      description: "The session chip's wash with the kind's icon and the title only.",
    },
    "kind-title": {
      label: "Kind and title",
      description: "The kind as a muted word before the title (Workspace · cmux next), no icon.",
    },
    link: {
      label: "Link",
      description: "The link as written, as before.",
    },
  },
  defaultArm: "icon-title-host",
});

export type CmuxLinkLook = keyof typeof cmuxLinkLook.arms;
