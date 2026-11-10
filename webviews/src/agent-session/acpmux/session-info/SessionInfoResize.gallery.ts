// l10n-allow-file: gallery fixtures (sample prompts), not shipped UI.
// A resize never opens or closes Session Info (Leo, 2026-11-10: "It's the resizing of the window
// itself, potentially. I don't know, I haven't tested myself yet, but I suspect that might be a thing.
// Like the size of the window itself being resized or whatever. Maybe making a new workspace. Like
// that might be it."). A pane under the breakpoint (sessionInfoFits: 648px) holds a saved open closed
// until the toggle; before 2026-11-10 the pane widening past it opened the panel by itself. Each play
// crosses the breakpoint in both directions and fails if what the toggle shows ever changes.
// test/session-info-resize-browser.test.ts runs these at a narrow and a wide window.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, CWD, noChat, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";

const rows = [
  user("Add retries to the fetch helper, with a backoff.", 4),
  assistant("Added `withRetry` around `fetchJson`: three tries, 200ms doubling.", 3),
];
const savedChat = chat(rows);

/// A new chat in a new workspace: its session started (prewarmed), nothing sent or opened yet.
const newChat = noChat([], {
  sessionId: "new-workspace-chat",
  summary: {
    sessionId: "new-workspace-chat",
    cwd: CWD,
    harness: "claude",
    turnCount: 0,
    host: "This Mac",
    hostKind: "local",
  },
});

/// Session Info on, as the App's header state has it by default (AgentPaneTunables `agent.sessionInfo`).
const native = { "pane.tabState": { inspector: true } };

/// Each side of the breakpoint, both ways, then wider than any preset.
const CROSSINGS = [560, 900, 560, 1300, 420, 900];
/// A new workspace's pane settling: it lays out small, then takes the window.
const SETTLING = [360, 640, 900, 1300];

const TOGGLE = "button.acpmux-session-info-toggle";
const pressed = (ctx: PlayContext) => ctx.document.querySelector(TOGGLE)?.getAttribute("aria-pressed") === "true";
const shown = (ctx: PlayContext) =>
  ctx.document.querySelector("aside.acpmux-session-info")?.getAttribute("data-presence") === "shown";

/// Resizes to each width; after each, once the pane has it and has laid out, Session Info is as it
/// was before the first resize. `expect`: what it must be from the start.
const holdsAcross =
  (widths: readonly number[], expect?: boolean, open = false) =>
  async (ctx: PlayContext) => {
    await ctx.waitFor(() => ctx.document.querySelector(TOGGLE));
    if (open && !pressed(ctx)) {
      await ctx.click({ selector: TOGGLE });
      await ctx.waitFor(() => shown(ctx));
    }
    const was = pressed(ctx);
    if (expect !== undefined && was !== expect)
      throw new Error(`Session Info starts ${was ? "open" : "closed"}, not ${expect ? "open" : "closed"}`);
    for (const width of widths) {
      await ctx.resize(width);
      await ctx.waitFor(() => {
        const pane = ctx.document.querySelector<HTMLElement>(".acpmux-shell");
        return !!pane && Math.abs(pane.clientWidth - width) <= 1;
      });
      // Two frames: the pane's ResizeObserver and the render it causes.
      for (let frame = 0; frame < 2; frame++) await new Promise((done) => requestAnimationFrame(() => done(null)));
      if (pressed(ctx) !== was || shown(ctx) !== was)
        throw new Error(`At ${width}px Session Info ${was ? "closed" : "opened"} by itself`);
    }
  };

export default agentPaneEntry({
  id: "agent-pane.session-info-resize",
  title: "Session Info stays as it is across resizes and in a new workspace",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 560, normal: 900, wide: 1300 },
  checks: {
    layoutShiftMax: {
      value: 1,
      reason: "Each step resizes the window: the chat reflows to the new width, which is the step, not a shift.",
    },
  },
  covers: [
    "agent-session/acpmux/session-info/useSessionInfo.tsx",
    "agent-session/acpmux/session-info/sessionInfoState.ts",
  ],
  variants: {
    narrow: {
      note: "Saved open, in a pane under 648px: held closed, the chat alone, until the toggle opens it.",
      snapshot: savedChat,
      native,
      sessionInfoOpen: true,
    },
    wide: {
      note: "Saved open, in a pane with room beside the chat: it shows, as the person left it.",
      snapshot: savedChat,
      native,
      sessionInfoOpen: true,
    },
    "after-resize": {
      note: "Saved open, then the window resized across 648px both ways: held closed when it started narrow, open when it started wide, and never toggled by a resize.",
      snapshot: savedChat,
      native,
      sessionInfoOpen: true,
      play: holdsAcross(CROSSINGS),
    },
    "opened-then-resized": {
      note: "Opened with the toggle, then resized across 648px both ways: it stays open, a popover while narrow.",
      snapshot: savedChat,
      native,
      play: holdsAcross(CROSSINGS, undefined, true),
    },
    "new-workspace": {
      note: "A new workspace's new chat while its pane settles from 360px to the window: Session Info stays closed.",
      snapshot: newChat,
      native,
      ready: { tab: "tab-new-workspace" },
      play: holdsAcross(SETTLING, false),
    },
    "new-chat-resized": {
      note: "A new chat, resized across 648px both ways: closed throughout.",
      snapshot: newChat,
      native,
      play: holdsAcross(CROSSINGS, false),
    },
  },
});
