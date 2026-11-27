// l10n-allow-file: gallery fixtures, not shipped UI.
// Leo, 2026-11-24: "honestly there's something incredibly google docs-y about this. discord-y. ... i
// think there's even situations where we can have an icon maybe toggle somewhere omnipresent... say the
// bottom left of the sidebar area, which is currently not used for anything. because we hid spaces by
// default". Four designs of that icon in every state; each is clickable (the popover), and the
// walk-through variants carry a state picker. Light and dark follow the gallery's appearance switch.
import { componentEntry } from "../gallery/format";
import type { AutoCloudDesign, AutoCloudStatusProps } from "./AutoCloudStatus";
import { AUTO_CLOUD_MATRIX_STATES } from "./autocloudStatusMatrix";

const designs: Record<AutoCloudDesign, string> = {
  glyph: "A: one glyph, status ring, count badge",
  pill: "B: compact pill, avatars and a sync dot",
  split: "C: two slots, AutoCloud toggle and presence",
  strip: "D: Discord-style strip, only when something is going on",
};
const variants: Record<string, { note: string; props: AutoCloudStatusProps }> = {};
for (const design of Object.keys(designs) as AutoCloudDesign[]) {
  for (const state of AUTO_CLOUD_MATRIX_STATES) {
    variants[`${design}-${state}`] = { note: `${designs[design]}; state ${state}`, props: { design, state } };
  }
  variants[`${design}-popover`] = {
    note: `${designs[design]}; the popover open`,
    props: { design, state: "crowd", open: true },
  };
  variants[`${design}-popover-offline`] = {
    note: `${designs[design]}; popover, offline with edits queued`,
    props: { design, state: "offline-here", open: true },
  };
  variants[`${design}-spaces`] = {
    note: `${designs[design]}; Spaces on: the dots keep the middle, the icon sits before them`,
    props: { design, state: "syncing", spaces: true },
  };
  variants[`${design}-walkthrough`] = {
    note: `${designs[design]}; click the icon, pick a state`,
    props: { design, state: "synced", simulate: true },
  };
}

export default componentEntry<AutoCloudStatusProps>({
  id: "sidebar.autocloud-status",
  title: "AutoCloud status icon (sidebar footer, bottom left): four designs",
  area: "Sidebar",
  experimental: true,
  covers: ["sidebar/AutoCloudStatus.tsx#AutoCloudStatusDesigns"],
  height: 400,
  keywords: ["autocloud", "presence", "sync", "here", "cloud", "footer", "status", "icon"],
  load: () => import("./AutoCloudStatus").then((module) => module.AutoCloudStatusDesigns),
  variants,
});
