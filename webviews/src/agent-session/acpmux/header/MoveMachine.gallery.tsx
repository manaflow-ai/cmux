// l10n-allow-file: gallery fixtures, not shipped UI.
import { createElement } from "react";
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { ChatHeaderTools } from "./ChatHeaderTools";
import type { HeaderMoveTarget } from "./headerState";
import { moveMachineRow } from "./chatRows";
import { translate } from "../i18n";

type Props = ComponentProps<typeof ChatHeaderTools>;
const noop = () => undefined;
const props = (targets: readonly HeaderMoveTarget[]): Props => ({
  onTerminal: noop,
  onBrowser: noop,
  summary: null,
  menu: () => {
    const row = moveMachineRow({ move: true, bringBack: false, targets }, { moveTo: noop, bringBack: noop }, translate);
    return row ? [row] : [];
  },
});
const auto: HeaderMoveTarget = { id: "auto", label: "Auto", kind: "auto", status: "Build box · room for 5" };
const cloud: HeaderMoveTarget = { id: "cloud-1", label: "Cloud machine", kind: "cloud" };
const build: HeaderMoveTarget = { id: "build-box", label: "Build box", kind: "ssh", status: "room for 5" };
const busy: HeaderMoveTarget = { id: "busy-box", label: "Review box", kind: "ssh", status: "busy" };
const open: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Chat actions" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));
  await ctx.focus({ role: "menuitem", name: "Move to…" });
  await ctx.press("ArrowRight");
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menu"]').length === 2);
};
export default componentEntry<Props>({
  id: "agent-pane.move-machine",
  title: "Move chat to a machine",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 390, normal: 680 },
  anchors: [{ selector: ".acpmux-header-tools" }],
  covers: ["agent-session/acpmux/header/chatRows.ts#moveMachineRow"],
  load: () =>
    import("./ChatHeaderTools").then((module) => (value: Props) => createElement(module.ChatHeaderTools, value)),
  styles: () => Promise.all([import("../styles.css"), import("../../../ui/popupSurface.css"), import("./header.css")]),
  variants: {
    "auto-cloud-ssh": {
      note: "Auto first, existing Cloud row and added SSH machines with placement room.",
      props: props([auto, cloud, build, busy]),
      play: open,
    },
    "from-ssh": {
      note: "A remote chat can return to This Mac or move to another machine.",
      props: props([auto, { id: "local", label: "", kind: "local" }, build]),
      play: open,
    },
    "unknown-and-unavailable": {
      note: "Unknown room is honest; a connected non-SSH peer remains visible with its refusal.",
      props: props([
        { id: "auto", label: "Auto", kind: "auto", reason: "No machine available" },
        { id: "new-box", label: "New box", kind: "ssh", status: "room unknown" },
        { id: "hub-box", label: "Hub box", kind: "remote", reason: "Moving requires an SSH connection" },
      ]),
      play: open,
    },
  },
});
