// l10n-allow-file: sample transcript and comparison notes, not shipped UI.
// The transcript's one jump control (VirtualTranscript.tsx JumpToLatest, jumpControl.ts;
// design/transcript-overlays.md) in the whole pane. Leo, 2026-11-10, of a capture with Jump up stacked
// on Jump to latest and the unread pill under them: "There's also no point doubling up on this", and
// "this jump to last read is not themed, like the jump to top thing ... this should be more selective.
// And it also needs to work better with when there is truly some unread stuff from the past."
// References: Jump to latest's own disc (agent-pane.jump-latest-centered, the fisheye lens) and chat
// apps' unread count on their jump-down button. One disc, its glass, size, place and fade unchanged:
// up with the count while unread turns lie above, down to the latest message while scrolled up, the
// Needs your input pill while an ask waits, and nothing at the latest message with nothing unread.
// View every variant at each width, and in light and dark (?colorScheme=light / dark).
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { assistant, chat, row, session, summary, user } from "../../gallery/fixtures/acpmux";
import { SINCE_DIVIDER, type AcpmuxPermission } from "./model";

const MARK = "gallery-jump-control:41";

const turns = (from: number, count: number, ago: number) =>
  Array.from({ length: count }, (_, index) => [
    user(`Check retry case ${from + index}`, ago - index * 2),
    assistant(
      `Case ${from + index} passes. The client retries a temporary transport failure, keeps the original request id, and stops after the last attempt. `.repeat(
        3,
      ),
      ago - index * 2 - 1,
    ),
    summary(ago - index * 2 - 1, { status: "completed" }),
  ]).flat();

const line = row(SINCE_DIVIDER, 60, { id: SINCE_DIVIDER, since: { key: MARK, seq: 41, turns: 9 } });
// Twelve turns the person saw, the line, then nine that ended while they were away.
const unread = chat([...turns(1, 12, 120), line, ...turns(13, 9, 58)], { sinceKey: MARK });
// The same chat with nothing unread: the person saw all of it.
const read = chat([...turns(1, 21, 120)]);

// A chat this one started waits on an answer (acpmux `startedBy`): the control is the Needs you pill.
const started = session({
  sessionId: "s-tests",
  title: "Run the integration tests",
  startedBy: unread.sessions[0]!.sessionId,
  shortName: "tests",
  pendingPermissions: 1,
  indicator: "input",
  updatedAt: Date.now() - 2 * 60_000,
});
const startedAsk: AcpmuxPermission = {
  permissionId: "ask-tests",
  title: "Start the test database",
  kind: "execute",
  command: "docker compose up -d db",
  pending: true,
  options: [
    { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
    { id: "reject_once", name: "Deny", kind: "reject_once", allow: false },
  ],
};
const needsYou = {
  ...unread,
  sessions: [unread.sessions[0]!, started],
  asks: [{ sessionId: started.sessionId, at: Date.now() - 2 * 60_000, permission: startedAsk }],
};

const settle = async (ctx: Parameters<Play>[0]) =>
  ctx.waitFor(() => (ctx.document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollHeight ?? 0) > 1_500);

/// Every jump control drawn: the variant fails when there is more than one, or one of the old ones.
const one = (ctx: Parameters<Play>[0]) => {
  // The Needs you pill is the same control (needsYou/JumpPill.tsx): it carries the class too.
  const all = ctx.document.querySelectorAll(".acpmux-jump-latest");
  const old = ctx.document.querySelectorAll(".acpmux-jump-up, .acpmux-since-jump");
  if (all.length !== 1 || old.length !== 0)
    throw new Error(`one jump control, not ${all.length} (and ${old.length} of the old ones)`);
};

const shown =
  (jump: "unread" | "latest"): Play =>
  async (ctx) => {
    await settle(ctx);
    await ctx.waitFor(() => ctx.document.querySelector(`.acpmux-jump-latest[data-jump="${jump}"][data-shown]`));
    one(ctx);
  };

/// Scrolled up by hand to the middle of the chat.
const scrolledUp =
  (jump: "unread" | "latest"): Play =>
  async (ctx) => {
    await settle(ctx);
    await ctx.scroll({ selector: ".acpmux-scroll" }, 1_400);
    await ctx.waitFor(() => ctx.document.querySelector(`.acpmux-jump-latest[data-jump="${jump}"][data-shown]`));
    one(ctx);
  };

export default agentPaneEntry({
  id: "agent-pane.jump-control",
  title: "The jump control: one disc for every jump",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 900, wide: 1600 },
  covers: ["agent-session/acpmux/VirtualTranscript.tsx#JumpToLatest", "agent-session/acpmux/jumpControl.ts"],
  keywords: ["jump to latest", "jump to bottom", "unread", "new since", "jump up", "needs your input"],
  variants: {
    "unread-above": {
      note: "Back in a chat that kept working, at its latest message: the disc points up to New since you looked and carries the 9 new turns in the theme's accent.",
      snapshot: unread,
      play: shown("unread"),
    },
    "double-control-regression": {
      note: "Leo's capture (two discs and the unread pill): scrolled up with the line still above, there is still one disc, up, with the count.",
      snapshot: unread,
      play: scrolledUp("unread"),
    },
    "latest-only": {
      note: "Nothing unread, scrolled up: Jump to latest alone, the arrow down. No jump up to a last prompt or a last stop.",
      snapshot: read,
      play: scrolledUp("latest"),
    },
    "after-unread": {
      note: "The up disc pressed: the transcript lands on the New line, and the same disc turns down to Jump to latest.",
      snapshot: unread,
      play: async (ctx) => {
        await shown("unread")(ctx);
        await ctx.click({ selector: ".acpmux-jump-latest" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-since"));
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-jump-latest[data-jump="latest"][data-shown]'));
        one(ctx);
      },
    },
    "needs-you": {
      note: "A chat this one started waits on an answer: the control is the Needs your input pill, ahead of the unread count, still one control.",
      snapshot: needsYou,
      play: async (ctx) => {
        await settle(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-needs-you-pill[data-shown]"));
        one(ctx);
      },
    },
    "unread-image": {
      note: "Over a background image: the same fisheye glass, the count in the theme's accent.",
      snapshot: unread,
      play: async (ctx) => {
        const root = ctx.document.documentElement;
        root.style.setProperty("background", `url("${wallpaper}") 0 0 / 100vw 100vh no-repeat fixed`, "important");
        root.style.setProperty("--agent-page-bg", "transparent");
        await shown("unread")(ctx);
      },
    },
  },
});
