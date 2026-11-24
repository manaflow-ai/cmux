// l10n-allow-file: gallery entry (titles and play checks), not shipped UI.
// The New Tab clock (`tabs.newTabClock.*`, NewTabClock.tsx; Leo 2026-11-16: "an aesthetic time thing
// like the ios home screen whatever customizer"): the iOS 26 Lock Screen's large time over the
// composer, in the looks the setting offers. The gallery's clock is GALLERY_NOW (09:41). The clock is
// off by default; each variant turns it on with one look.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { CWD, noChat } from "../../../gallery/fixtures/acpmux";
import type { NewTabClockStyle } from "./clockModel";

const page = (clock: NewTabClockStyle) => ({
  newTab: {
    layout: "b",
    kind: "agent",
    cwd: CWD,
    home: "/Users/you",
    lastAgent: "claude",
    clock,
  },
  newSession: true,
});

/// The clock draws over the composer, and the composer is still the page's.
const overComposer = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".nt-above-room .nt-clock-time") !== null);
  const time = ctx.document.querySelector(".nt-clock-time")!;
  const field = ctx.document.querySelector(".nt-field");
  if (!field) throw new Error("the composer is gone with the clock on");
  if (time.compareDocumentPosition(field) & 2) throw new Error("the clock draws under the composer");
};

export default agentPaneEntry({
  id: "agent-pane.new-tab-clock",
  title: "New Tab clock (Lock Screen time over the composer)",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/newtab/NewTabClock.tsx#NewTabClock"],
  variants: {
    "rounded-bold": {
      note: "The setting's default look once it is on: rounded, bold, the theme's text, the date over the time.",
      snapshot: noChat(),
      ready: page({ font: "rounded", weight: "bold", color: "text", date: true }),
      play: overComposer,
    },
    "thin-glass": {
      note: "Thin numerals in glass: the theme's text at a translucent tint with a soft rim of light.",
      snapshot: noChat(),
      ready: page({ font: "system", weight: "thin", color: "glass", date: true }),
      play: overComposer,
    },
    "serif-accent": {
      note: "Serif in the theme's accent.",
      snapshot: noChat(),
      ready: page({ font: "serif", weight: "regular", color: "accent", date: true }),
      play: overComposer,
    },
    "condensed-heavy": {
      note: "Condensed and heavy, the Lock Screen's tall stencil time, without the date.",
      snapshot: noChat(),
      ready: page({ font: "condensed", weight: "heavy", color: "text", date: false }),
      play: overComposer,
    },
    "mono-muted": {
      note: "Monospaced and muted: the quietest look.",
      snapshot: noChat(),
      ready: page({ font: "mono", weight: "regular", color: "muted", date: true }),
      play: overComposer,
    },
  },
});
