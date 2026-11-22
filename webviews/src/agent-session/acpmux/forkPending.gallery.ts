// l10n-allow-file: gallery fixtures, not shipped UI.
// Fork Conversation while acpmux forks, in the whole pane (Leo, 2026-11-06: "forking text is
// weird + it's so SLOW + i shuold be able to cancel a fork probably"). "before" is the transcript
// row the pane drew until now; the others are the pending state's looks, side by side at full
// size. Picked: "line", the host line's look above the composer (ForkPendingLine.tsx): it is the
// stack's one way of saying a wait (HostWaitingLine), it moves nothing in the transcript, and its
// Cancel sits where the eye already is. "pill" floats a capsule over the transcript's foot and
// reads as a toast; "composer" puts the wait inside the card, where it reads as the composer's
// own state though typing still works.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, row, summary, user } from "../../gallery/fixtures/acpmux";
import type { Play } from "../../gallery/play";
import type { AcpmuxRow } from "./model";

const rows: AcpmuxRow[] = [
  user("Find why the release build skips the asset step", 6),
  assistant(
    "The asset step is gated on `CI_RELEASE`, which the release job never sets: the workflow exports `RELEASE` instead. Renaming the check fixes it; I left the old name working for a release so no pipeline breaks.",
    5,
  ),
  summary(5, { durationMs: 74_000, toolCount: 6 }),
];
const before = chat([...rows, row("notice", 0, { text: "Forking…" })], { title: "Release asset step" });
const pending = (seconds: number) =>
  chat(rows, { title: "Release asset step", forkPending: { since: Date.now() - seconds * 1000 } });

const hasCancel: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector("[data-fork-pending]"));
  ctx.find({ role: "button", name: "Cancel" });
  if ([...ctx.document.querySelectorAll(".acpmux-scroll *")].some((node) => node.textContent === "Forking…"))
    throw new Error("The pending fork drew a transcript row");
};

/// The alternates restyle the shipped line in the page, so they never reach the app's CSS.
const ALTERNATES = `
[data-gallery-look="pill"] { position: absolute; left: 50%; bottom: calc(100% + 8px); transform: translateX(-50%);
  margin: 0; padding: 4px 6px 4px 12px; border-radius: 999px; background: var(--agent-surface, Canvas);
  box-shadow: 0 1px 2px rgb(0 0 0 / .12), 0 4px 16px rgb(0 0 0 / .12); }
.acpmux-composer:has([data-gallery-look="pill"]) { position: relative; }
[data-gallery-look="composer"] { margin: 0; padding: 6px 10px 0; }
`;
const restyled =
  (look: "pill" | "composer"): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector("[data-fork-pending]"));
    const line = ctx.find({ selector: "[data-fork-pending]" }) as HTMLElement;
    const style = ctx.document.createElement("style");
    style.textContent = ALTERNATES;
    ctx.document.head.append(style);
    // A copy, so React's own node stays where it put it (hidden).
    const copy = line.cloneNode(true) as HTMLElement;
    copy.dataset.galleryLook = look;
    line.hidden = true;
    const host = ctx.document.querySelector(look === "pill" ? ".acpmux-composer" : ".acpmux-composer-box");
    host?.prepend(copy);
    await hasCancel(ctx);
  };

export default agentPaneEntry({
  id: "agent-pane.fork-pending",
  title: "Fork Conversation while acpmux forks",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 400, normal: 760, wide: 960 },
  anchors: [{ selector: ".acpmux-composer-bar" }],
  covers: ["agent-session/acpmux/ForkPendingLine.tsx"],
  variants: {
    before: { snapshot: before, note: "Before: a bare Forking… row at the transcript's end, no way to stop it." },
    line: { snapshot: pending(0), play: hasCancel, note: "Picked. The host line's look above the composer." },
    "line-counting": {
      snapshot: pending(7),
      play: hasCancel,
      note: "Picked, past 2 s: the line counts how long the fork has taken.",
    },
    pill: {
      snapshot: pending(0),
      play: restyled("pill"),
      note: "Alternate, not shipped: a capsule over the transcript's foot. Reads as a toast.",
    },
    composer: {
      snapshot: pending(0),
      play: restyled("composer"),
      note: "Alternate, not shipped: the wait inside the composer card. Reads as the composer's own state.",
    },
  },
});
