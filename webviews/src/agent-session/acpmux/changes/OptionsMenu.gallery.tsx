// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { OptionsMenu, type OptionsRow } from "./OptionsMenu";

type Props = Record<string, never>;

const baseRows: OptionsRow[] = [
  { label: "Refresh files", run: () => undefined },
  null,
  { label: "Word wrap", run: () => undefined },
  { label: "Split view", disabled: true, run: () => undefined },
  { label: "Copy git apply command", run: () => undefined },
];

function GalleryOptionsMenu() {
  const [lastAction, setLastAction] = useState("No action yet");
  const rows = baseRows.map((row) => (row ? { ...row, run: () => setLastAction(row.label) } : row));
  return (
    <div className="acpmux-options-gallery-stage">
      <div className="acpmux-options-gallery-copy">
        <strong>Changes options</strong>
        <span>View toggles and file actions stay in one keyboardable menu.</span>
      </div>
      <OptionsMenu rows={rows} />
      <output aria-live="polite">{lastAction}</output>
    </div>
  );
}

const open: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Changes options" });
  await ctx.waitFor(() => ctx.find({ role: "menuitem", name: "Refresh files" }));
};

const keyboard: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Changes options" });
  await ctx.press("End");
  await ctx.waitFor(() => ctx.document.activeElement?.textContent === "Copy git apply command");
  await ctx.press("Escape");
  await ctx.waitFor(() => {
    const trigger = ctx.find({ role: "button", name: "Changes options" });
    return ctx.document.activeElement === trigger;
  });
};

const disabled: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Changes options" });
  await ctx.waitFor(() => ctx.find({ role: "menuitem", name: "Split view" }).getAttribute("aria-disabled") === "true");
};

export default componentEntry<Props>({
  id: "agent-pane.changes-options-menu",
  title: "Changes options menu",
  area: "Agent pane",
  height: 240,
  widths: { narrow: 320, normal: 480, wide: 640 },
  anchors: [{ selector: ".acpmux-file-menu" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Opening the options menu must leave its toolbar trigger anchored." },
    layoutShiftMax: { value: 0, reason: "The menu is portaled and must not add layout to the changes toolbar." },
    longFrameFailMs: { value: 33, reason: "Changes menu keyboard traversal should remain responsive." },
    settleMaxMs: { value: 250, reason: "Opening and dismissing a local options menu should settle quickly." },
  },
  covers: ["agent-session/acpmux/changes/OptionsMenu.tsx#OptionsMenu"],
  load: async () => GalleryOptionsMenu,
  styles: () => Promise.all([import("../styles.css"), import("./changes.css"), import("./OptionsMenu.gallery.css")]),
  variants: {
    closed: { props: {} },
    open: { props: {}, play: open },
    keyboard: { props: {}, play: keyboard },
    disabled: { props: {}, play: disabled },
  },
});
