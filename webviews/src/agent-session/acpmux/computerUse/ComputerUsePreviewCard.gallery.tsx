// l10n-allow-file: gallery fixtures (a sample app name and drawn frames), not shipped UI.
import { useLayoutEffect, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { SessionInfoPanel } from "../session-info/SessionInfo";
import { FLOAT_MARGIN, type SessionInfoPlacement } from "../session-info/sessionInfoModel";
import { useUnderSessionInfo } from "../session-info/underSessionInfo";
import { ComputerUsePreviewCard } from "./ComputerUsePreviewCard";
import {
  computerUsePreviewDocked,
  setComputerUsePreviewControls,
  useComputerUsePreviewControls,
  useComputerUsePreviewMoves,
  useComputerUsePreviewRoom,
  type ComputerUsePreview,
} from "./computerUsePreview";

/// A drawn stand-in for the helper's thumbnail of a calculator window (320 px wide, as the helper's are).
const frame = `data:image/svg+xml,${encodeURIComponent(
  `<svg xmlns="http://www.w3.org/2000/svg" width="320" height="480" viewBox="0 0 320 480">` +
    `<rect width="320" height="480" rx="24" fill="#2b2b2d"/>` +
    `<text x="296" y="120" fill="#fff" font-family="-apple-system,sans-serif" font-size="44" text-anchor="end">5,888</text>` +
    Array.from({ length: 20 }, (_, i) => {
      const x = 20 + (i % 4) * 72;
      const y = 160 + Math.floor(i / 4) * 62;
      const fill = i % 4 === 3 ? "#ff9f0a" : i < 4 ? "#5b5b5e" : "#3a3a3c";
      return `<circle cx="${x + 30}" cy="${y + 26}" r="26" fill="${fill}"/>`;
    }).join("") +
    `</svg>`,
)}`;

/// A drawn stand-in for the app's icon.
const icon = `data:image/svg+xml,${encodeURIComponent(
  `<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">` +
    `<rect x="8" y="8" width="80" height="80" rx="18" fill="#e9e9ec"/>` +
    `<rect x="22" y="20" width="52" height="16" rx="3" fill="#3a3a3c"/>` +
    `<g fill="#ff9f0a"><rect x="22" y="44" width="14" height="10" rx="2"/><rect x="41" y="44" width="14" height="10" rx="2"/>` +
    `<rect x="60" y="44" width="14" height="10" rx="2"/><rect x="22" y="60" width="14" height="10" rx="2"/>` +
    `<rect x="41" y="60" width="14" height="10" rx="2"/><rect x="60" y="60" width="14" height="10" rx="2"/></g>` +
    `</svg>`,
)}`;

/// The agent clicked the "=" key last: the card draws its cursor there.
const running: ComputerUsePreview = {
  session: "cua_native_1",
  app: "Calculator",
  done: false,
  frame,
  pointer: { x: 0.83, y: 0.9, click: 7 },
};
const done: ComputerUsePreview = { ...running, done: true, icon };

/// The person's pointer over the display, as the host sends it (a telepointer, never in the frame).
// motion-allow: a fixture pointer age
const personOver = { x: 0.3, y: 0.32, visible: true, ageMs: 120, idle: false };
const withPerson: ComputerUsePreview = {
  ...running,
  // motion-allow: a fixture pointer age
  telepointers: { agent: { x: 0.83, y: 0.9, visible: true, ageMs: 80, idle: false }, person: personOver },
};
const personOnly: ComputerUsePreview = {
  session: running.session,
  app: running.app,
  done: false,
  frame,
  telepointers: { person: personOver },
};

type Props = {
  preview: ComputerUsePreview;
  chat?: boolean;
  sessionInfo?: SessionInfoPlacement;
  dropTarget?: boolean;
  /// Labs > Show Preview Features off (the shipped default): no drag, no Full Size, no chip. The other
  /// variants show the card with it on.
  labsOff?: boolean;
};

/// A prompt long enough to reach the card's side: with the column's room kept, it wraps before the card.
const prompt =
  "Use cmux Computer Use to open the Calculator app and compute 128 x 46 by clicking its buttons. Do not use the shell. When done, say the result.";

/// Session Info's top: under the chat header, as the pane places it (SessionInfo.tsx sessionInfoTopOffset).
const UNDER_HEADER = "var(--acpmux-header-height, 44px)";

/// A short Session Info: the chat's folder and its changes (the Codex app's summary panel in Lucas's
/// reference, 2026-10-27).
function GallerySessionInfo({ placement }: { placement: SessionInfoPlacement }) {
  return (
    <SessionInfoPanel width={260} placement={placement} under={UNDER_HEADER}>
      <div className="acpmux-session-info__body" data-layout="glance">
        <div className="acpmux-session-info-group" data-group="about">
          <section className="acpmux-session-info-section">
            <div className="acpmux-session-info-row">cmux-diff-test</div>
          </section>
        </div>
        <div className="acpmux-session-info-group" data-group="made">
          <section className="acpmux-session-info-section">
            <div className="acpmux-session-info-row">Changes</div>
          </section>
        </div>
      </div>
    </SessionInfoPanel>
  );
}

function GalleryComputerUsePreview({ preview, chat, sessionInfo, dropTarget, labsOff }: Props) {
  const [shell, setShell] = useState<HTMLElement | null>(null);
  // As the pane does on Labs > Show Preview Features (pane/paneSnapshot.ts applyPreview).
  useLayoutEffect(() => {
    setComputerUsePreviewControls(!labsOff);
    return () => setComputerUsePreviewControls(false);
  }, [labsOff]);
  const movable = useComputerUsePreviewControls();
  // As the pane does (App.tsx): no card in a pane too narrow to keep its room. A close, a drag, a
  // resize or the chip goes through the page's store, which the card draws at once (no host here
  // to echo it).
  const room = useComputerUsePreviewRoom();
  const shown = room ? preview : null;
  // Moved, larger or hidden, the card no longer sits beside the column: the column takes its room back.
  const moved = useComputerUsePreviewMoves(shown);
  const beside = moved !== null && computerUsePreviewDocked(moved, movable) && !sessionInfo;
  // As Session Info does (SessionInfo.tsx SessionInfoPresence): it publishes where the card under it goes.
  useUnderSessionInfo(shell, sessionInfo !== undefined, sessionInfo === "push", FLOAT_MARGIN, UNDER_HEADER);
  return (
    <div
      ref={setShell}
      className="acpmux-shell"
      data-cu-preview-fixture
      data-session-info-chat-placement={sessionInfo}
      // The stage's viewport is the pane. A component stage's #root has no height of its own, so 100%
      // here was 0 and the shell's overflow clip hid the card: a click on Hide Preview missed it.
      style={{ position: "relative", height: "100vh" }}
    >
      {/* With Session Info open, the column keeps no room of its own for the card (App.tsx previewBeside). */}
      <div className="acpmux-main" data-cu-preview={beside ? "" : undefined}>
        <div className="acpmux-stage" style={{ height: "100%" }}>
          <ComputerUsePreviewCard preview={shown} onClose={() => {}} />
          {chat && (
            <div style={{ position: "relative", flex: 1, marginTop: 52 }}>
              <div className="acpmux-row acpmux-user" style={{ top: 0 }}>
                <div className="acpmux-user-bubble">{prompt}</div>
              </div>
            </div>
          )}
        </div>
      </div>
      {sessionInfo && <GallerySessionInfo placement={sessionInfo} />}
      {/* Where the drag play lets go: the pane's bottom left. */}
      {dropTarget && (
        <div
          className="acpmux-cu-preview-drop-target"
          aria-hidden="true"
          style={{ position: "absolute", left: 16, bottom: 16, width: 8, height: 8, pointerEvents: "none" }}
        />
      )}
    </div>
  );
}

/// A click on the card: it enlarges.
const expand =
  (name: string): Play =>
  async (ctx) => {
    await ctx.click({ role: "button", name });
  };

/// The close button hovered: a little brighter and a little larger.
const closeHover: Play = async (ctx) => {
  await ctx.hover({ role: "button", name: "Hide Preview" });
};

/// A close: the card gives way to its Show Preview chip, where the card sat.
const close: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Hide Preview" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cu-preview[data-hidden]"));
};

/// The chip brings the card back.
const showAgain: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Show Preview" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cu-preview:not([data-hidden])"));
};

/// A press on the card that moves drags it: down on the card, across to the pane's bottom left, up.
const drag =
  (name: string): Play =>
  async (ctx) => {
    await ctx.pointer.down({ role: "button", name });
    await ctx.pointer.move({ selector: "[data-cu-preview-fixture] .acpmux-cu-preview-drop-target" });
    await ctx.pointer.up({ selector: "[data-cu-preview-fixture] .acpmux-cu-preview-drop-target" });
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cu-preview[data-placed]"));
  };

/// Full Size, from the card's button.
const fullSize: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Full Size" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cu-preview[data-full]"));
};

/// Each variant its own session: a move stays in the page's store for its session.
const as = (session: string, preview: ComputerUsePreview = running): ComputerUsePreview => ({ ...preview, session });

export default componentEntry<Props>({
  id: "agent-pane.computer-use-preview",
  title: "Computer use live preview",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 360, normal: 640, wide: 900 },
  anchors: [{ selector: "[data-cu-preview-fixture]" }],
  covers: [
    "agent-session/acpmux/computerUse/ComputerUsePreviewCard.tsx#ComputerUsePreviewCard",
    "agent-session/acpmux/session-info/underSessionInfo.ts",
  ],
  styles: () =>
    Promise.all([
      import("../../../ui/glass/glass.css"),
      import("../styles.css"),
      import("../composerStates.css"),
      import("../conversation/conversation.css"),
      import("../session-info/sessionInfo.css"),
    ]),
  load: async () => GalleryComputerUsePreview,
  variants: {
    running: {
      note: "While the agent uses the app: its window alone, with its own rounded corners and a soft shadow, no card around it. The small dark close button sits on its top left corner. The name is in the label only.",
      props: { preview: running },
    },
    done: {
      note: "After the session ended: the window dims, the app's icon (40px) scales in at its center and a 16px green check scales in on the icon's corner, neither past its size. The host hides it 30 s later, with a short fade and scale down.",
      props: { preview: done },
    },
    "done-no-icon": {
      note: "Done, with no icon found: the check alone, a little larger.",
      props: { preview: { ...done, icon: undefined } },
    },
    "agent-only": {
      note: "Only the agent's cursor: the helper's dart at the window's scale, at its last click, as before. The person's pointer is not over the window.",
      props: { preview: { ...running, telepointers: { agent: { x: 0.83, y: 0.9, visible: true, idle: false } } } },
    },
    "agent-only-before": {
      note: "Before: between the agent's actions its cursor was gone, so the window showed no sign of the agent while it thought. Now the cursor stays at its last click until the turn ends (agent-only).",
      props: { preview: { ...running, pointer: undefined } },
    },
    "both-pointers": {
      note: "Co-driving: the agent's cursor at the = key and the person's pointer over the display, a plain arrow in the page's text tone labelled You on a small-radius rect. Both are metadata over the frame, never in its pixels; the agent's cursor draws on top.",
      props: { preview: withPerson },
    },
    "person-only": {
      note: "Only the person's pointer: the agent's cursor has not shown in the window yet.",
      props: { preview: personOnly },
    },
    "person-idle": {
      note: "The person's pointer has stayed still for 2 s: it dims, so the agent's cursor reads first.",
      props: {
        preview: {
          ...withPerson,
          telepointers: { ...withPerson.telepointers, person: { ...personOver, ageMs: 2400, idle: true } },
        },
      },
    },
    "person-outside": {
      note: "The person's pointer left the window: it fades out where it crossed the edge; the agent's cursor stays.",
      props: {
        preview: {
          ...withPerson,
          telepointers: { ...withPerson.telepointers, person: { x: 1, y: 0.32, visible: false, idle: false } },
        },
      },
    },
    "beside-chat": {
      note: "The column keeps the card's room: the prompt wraps before the card, nothing runs under it. Narrow panes show no card.",
      props: { preview: running, chat: true },
    },
    "beside-inspector": {
      note: "Session Info open over the chat: the card sits directly under its card, 8px below, right-aligned with it. Closed, the card is back at the top right.",
      props: { preview: running, chat: true, sessionInfo: "overlay" },
    },
    "under-pushed-inspector": {
      note: "Session Info pushing the chat (Settings Push always): the card sits under it, outside the chat, which keeps no room for it.",
      props: { preview: running, chat: true, sessionInfo: "push" },
    },
    "close-hover": {
      note: "The close button hovered: its fill a little brighter, scaled up a little. The card itself does not move on hover.",
      props: { preview: running },
      play: closeHover,
    },
    expanded: {
      note: "A click on the card enlarges it over the chat's top right (as the Codex app does); another click shrinks it back.",
      props: { preview: running, chat: true },
      play: expand("Calculator, live"),
      checks: {
        layoutShiftMax: {
          value: 0.025,
          reason:
            "The click enlarges the card and the column takes back the room it kept for the small card (measured 0.014-0.016): the reflow is the design.",
        },
      },
    },
    "expanded-done": {
      note: "Enlarged when the agent's Computer Use ended: the last frame, dimmed, with the check.",
      props: { preview: { ...running, done: true } },
      play: expand("Calculator, done"),
      checks: {
        layoutShiftMax: {
          value: 0.025,
          reason:
            "The click enlarges the card: its own box grows over the chat's top right, which is the step's point.",
        },
      },
    },
    close: {
      note: 'A close: the card gives way to a small Show Preview chip where it sat (Leo, 2026-11-22, asking for "the ability to drag it around and" hide it). Before, the card was gone with no way back.',
      props: { preview: as("cua_gallery_close") },
      play: close,
      checks: {
        layoutShiftMax: {
          value: 0.002,
          reason:
            "Hide leaves the smaller Show Preview chip, so the column takes back the rest of the card's room (measured 0.0005).",
        },
      },
    },
    "hidden-chip": {
      note: "Hidden: only the chip, the Computer Use eye and Show Preview, at the card's top right. A click brings the card back with its newest frame.",
      props: { preview: { ...as("cua_gallery_chip"), hidden: true } },
    },
    "hidden-chip-moved": {
      note: "Hidden after a drag to the bottom left: the chip sits where the card was, so it comes back where it was put.",
      props: { preview: { ...as("cua_gallery_chip_moved"), hidden: true, place: { x: 0, y: 1, size: "small" } } },
    },
    "hidden-chip-show": {
      note: "The chip clicked: the card is back where it was.",
      props: { preview: { ...as("cua_gallery_chip_show"), hidden: true } },
      play: showAgain,
    },
    dragged: {
      note: "Dragged to the pane's bottom left: the card stays inside the pane at any size, and the column takes its room back.",
      props: { preview: { ...as("cua_gallery_dragged"), place: { x: 0, y: 1, size: "small" } }, chat: true },
    },
    "dragged-middle": {
      note: "Dragged to the middle of the left edge: a place is a fraction of the room the pane leaves around the card.",
      props: { preview: { ...as("cua_gallery_middle"), place: { x: 0, y: 0.5, size: "small" } }, chat: true },
    },
    drag: {
      note: "A press that moves past 4 px drags the card (a grabbing cursor while it moves); a press that does not move still enlarges it.",
      props: { preview: as("cua_gallery_drag"), chat: true, dropTarget: true },
      play: drag("Calculator, live"),
      checks: {
        layoutShiftMax: {
          value: 0.08,
          reason:
            "The drop moves the card where the person put it and the column takes back the room it kept at the top right (measured 0.061).",
        },
      },
    },
    "full-size": {
      note: 'Full Size: the frame fills the pane, letterboxed, over the chat; Exit Full Size (or a click on the frame) shrinks it back. Leo, 2026-10-29: "why can\'t I full screen this picture?"',
      props: { preview: { ...as("cua_gallery_full"), place: { x: 1, y: 0, size: "full" } }, chat: true },
    },
    "full-size-play": {
      note: "The Full Size button on the card's top right, clicked.",
      props: { preview: as("cua_gallery_full_play") },
      play: fullSize,
      checks: {
        layoutShiftMax: {
          value: 0.85,
          reason:
            "Full Size makes the card fill the pane, as the person asked (measured 0.767): the card's own box is the shift.",
        },
      },
    },
    "labs-off": {
      note: "Labs > Show Preview Features off (the default): the card a host placed at the bottom left still draws at the top right, small, with no Full Size button; a press does not drag it.",
      props: {
        preview: { ...as("cua_gallery_labs_off"), place: { x: 0, y: 1, size: "small" } },
        chat: true,
        labsOff: true,
      },
    },
    "labs-off-expanded": {
      note: "Labs off: a click still enlarges the card over the chat's top right, and the column keeps the room it kept for the small card.",
      props: { preview: as("cua_gallery_labs_off_expanded"), chat: true, labsOff: true },
      play: expand("Calculator, live"),
      checks: {
        layoutShiftMax: {
          value: 0.025,
          reason:
            "The click enlarges the card: its own box grows over the chat's top right, which is the step's point.",
        },
      },
    },
    "labs-off-close": {
      note: "Labs off: a close takes the card away for the session, with no Show Preview chip, as before.",
      props: { preview: as("cua_gallery_labs_off_close"), labsOff: true },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Hide Preview" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cu-preview") === null);
      },
      checks: {
        layoutShiftMax: {
          value: 0.002,
          reason: "Hide takes the card away; nothing else in the pane moves.",
        },
      },
    },
    "full-size-done": {
      note: "Full size when the agent's Computer Use ended: the last frame dimmed, the icon and check at its center.",
      props: { preview: { ...as("cua_gallery_full_done", done), place: { x: 1, y: 0, size: "full" } } },
    },
  },
});
