// l10n-allow-file: gallery entry (titles and play checks), not shipped UI.
// The New Tab page's three dots (newtab/tabDots.ts; Leo 2026-10-23: "1 CLAUDE MINIMAL / 2 CLAUDE
// MINIMAL + NEW TAB/TERMINAL/WHATEVER / 3 CODEX MINIMAL"), each one picked: the same default page
// with Claude's composer alone, with the quick action pills under it, and with Codex's composer.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { CWD, manySessions, noChat } from "../../../gallery/fixtures/acpmux";
import { setComposerLook } from "../composerLook";
import { DOT_STATES, type NewTabDot } from "./tabDots";

const page = (dot: NewTabDot) => ({
  newTab: {
    layout: "b",
    kind: "agent",
    cwd: CWD,
    home: "/Users/you",
    lastAgent: "claude",
    // The host's widget list: none (Settings' default, no headline), and the quick actions for the second dot.
    pageWidgets: DOT_STATES[dot].actions ? ["actions"] : [],
  },
  newSession: true,
});

/// The dot's look, shown and not remembered (the look is the viewer's, kept in storage), then the
/// dot marked.
const pick = (dot: NewTabDot) => async (ctx: PlayContext) => {
  setComposerLook(DOT_STATES[dot].look, { remember: false });
  await ctx.waitFor(() => ctx.document.querySelector(`.nt-look-dots input[value=${dot}]:checked`) !== null);
  const pills = ctx.document.querySelectorAll(".nt-create [data-create]").length;
  if (pills !== (DOT_STATES[dot].actions ? 3 : 0)) throw new Error(`the ${dot} dot shows ${pills} pills`);
  const dots = ctx.document.querySelectorAll(".nt-style input[type=radio]").length;
  if (dots !== 3) throw new Error(`the page shows ${dots} dots, not three`);
};

export default agentPaneEntry({
  id: "agent-pane.new-tab-dots",
  title: "New Tab dots (Claude Minimal, Claude + Quick Actions, Codex Minimal)",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/newtab/PageDots.tsx#PageDots"],
  variants: {
    "claude-minimal": {
      note: "The first dot, Claude Minimal (the default): Claude's composer alone, the three dots under the page, the first marked.",
      ready: page("claude"),
      snapshot: noChat(manySessions(6)),
      play: pick("claude"),
    },
    "claude-actions": {
      note: "The second dot, Claude Minimal with the quick actions: the same composer with New terminal, New browser tab and New chat as quiet pills under it.",
      ready: page("claudeActions"),
      snapshot: noChat(manySessions(6)),
      play: pick("claudeActions"),
    },
    "codex-minimal": {
      note: "The third dot, Codex Minimal: Codex's composer alone, the model in the box's row and the folder strip a tray over the box.",
      ready: page("codex"),
      snapshot: noChat(manySessions(6)),
      play: pick("codex"),
    },
  },
});
