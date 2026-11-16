// l10n-allow-file: gallery entry (titles and play checks), not shipped UI.
// The New Tab page's look dots (newtab/tabDots.ts; Leo 2026-10-23: "1 CLAUDE MINIMAL ... 3 CODEX
// MINIMAL"), each one picked: the same default page with Claude's composer and with Codex's.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { CWD, manySessions, noChat } from "../../../gallery/fixtures/acpmux";
import { setComposerLook } from "../composerLook";
import { DOT_LOOKS, NEW_TAB_DOTS, type NewTabDot } from "./tabDots";

const page = {
  newTab: {
    layout: "b",
    kind: "agent",
    cwd: CWD,
    home: "/Users/you",
    lastAgent: "claude",
  },
  newSession: true,
};

/// The dot's look, shown and not remembered (the look is the viewer's, kept in storage), then the
/// dot marked.
const pick = (dot: NewTabDot) => async (ctx: PlayContext) => {
  setComposerLook(DOT_LOOKS[dot], { remember: false });
  await ctx.waitFor(() => ctx.document.querySelector(`.nt-look-dots input[value=${dot}]:checked`) !== null);
  const pills = ctx.document.querySelectorAll(".nt-create [data-create]").length;
  if (pills !== 0) throw new Error(`the ${dot} dot shows ${pills} pills`);
  const dots = ctx.document.querySelectorAll(".nt-style input[type=radio]").length;
  if (dots !== NEW_TAB_DOTS.length) throw new Error(`the page shows ${dots} dots, not ${NEW_TAB_DOTS.length}`);
};

export default agentPaneEntry({
  id: "agent-pane.new-tab-dots",
  title: "New Tab dots (Claude Minimal, Codex Minimal)",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/newtab/PageDots.tsx#PageDots"],
  variants: {
    "claude-minimal": {
      note: "The first dot, Claude Minimal (the default): Claude's composer alone, the two dots under the page, the first marked.",
      ready: page,
      snapshot: noChat(manySessions(6)),
      play: pick("claude"),
    },
    "codex-minimal": {
      note: "The second dot, Codex Minimal: Codex's composer alone, the model in the box's row and the folder strip a tray over the box.",
      ready: page,
      snapshot: noChat(manySessions(6)),
      play: pick("codex"),
    },
  },
});
