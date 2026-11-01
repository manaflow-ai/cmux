// l10n-allow-file: gallery fixtures (a sample app name and drawn frames), not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { FLOAT_MARGIN, SessionInfoPanel, type SessionInfoPlacement } from "../session-info/SessionInfo";
import { useUnderSessionInfo } from "../session-info/underSessionInfo";
import { ComputerUsePreviewCard } from "./ComputerUsePreviewCard";
import { useComputerUsePreviewRoom, type ComputerUsePreview } from "./computerUsePreview";

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

type Props = { preview: ComputerUsePreview; chat?: boolean; sessionInfo?: SessionInfoPlacement };

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

function GalleryComputerUsePreview({ preview, chat, sessionInfo }: Props) {
  const [closed, setClosed] = useState(false);
  const [shell, setShell] = useState<HTMLElement | null>(null);
  // As the pane does (App.tsx): no card in a pane too narrow to keep its room.
  const room = useComputerUsePreviewRoom();
  const shown = room && !closed ? preview : null;
  // As Session Info does (SessionInfo.tsx SessionInfoPresence): it publishes where the card under it goes.
  useUnderSessionInfo(shell, sessionInfo !== undefined, sessionInfo === "push", FLOAT_MARGIN, UNDER_HEADER);
  return (
    <div
      ref={setShell}
      className="acpmux-shell"
      data-cu-preview-fixture
      data-session-info-chat-placement={sessionInfo}
      // A component stage's #root has no height of its own, so 100% here was 0 and the shell's
      // overflow clip hid the card from a click; the stage's viewport is the pane.
      style={{ position: "relative", height: "100vh" }}
    >
      {/* With Session Info open, the column keeps no room of its own for the card (App.tsx previewBeside). */}
      <div className="acpmux-main" data-cu-preview={shown && !sessionInfo ? "" : undefined}>
        <div className="acpmux-stage" style={{ height: "100%" }}>
          <ComputerUsePreviewCard preview={shown} onOpen={() => {}} onClose={() => setClosed(true)} />
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
    </div>
  );
}

/// The close button hovered: a little brighter and a little larger.
const closeHover: Play = async (ctx) => {
  await ctx.hover({ role: "button", name: "Hide Preview" });
};

/// A close plays the card's exit, then the card is gone.
const close: Play = async (ctx) => {
  const d = ctx.document;
  const r = (q: string) => { const e = d.querySelector<HTMLElement>(q); if (!e) return `${q}:none`; const b = e.getBoundingClientRect(); return `${q}:${Math.round(b.left)},${Math.round(b.top)} ${Math.round(b.width)}x${Math.round(b.height)}`; };
  const btn = d.querySelector<HTMLElement>(".acpmux-cu-preview__close") ?? d.querySelector<HTMLElement>('[aria-label="Hide Preview"]');
  const bb = btn?.getBoundingClientRect();
  const hit = bb ? d.elementFromPoint(bb.left + bb.width / 2, bb.top + bb.height / 2) : null;
  const before = [r("html"), r("body"), r("#root"), r("[data-cu-preview-fixture]"), r(".acpmux-stage"), r(".acpmux-cu-preview"), `btn:${btn?.className}`, `hit:${hit?.tagName}.${hit?.className}`].join(" | ");
  await ctx.click({ role: "button", name: "Hide Preview" });
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-cu-preview")).catch(() => {
    const card = d.querySelector<HTMLElement>(".acpmux-cu-preview");
    throw new Error(`DIAG close: before ${before}; after card ${card?.className} ${[...(card?.attributes ?? [])].map((a) => `${a.name}=${a.value}`).join(",")} anim=${card?.getAnimations().length}`);
  });
};

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
      note: "After the session ended: the window dims, the app's icon (40px) scales in at its center and a 16px green check pops in on the icon's corner. The host hides it 30 s later, with a short fade and scale down.",
      props: { preview: done },
    },
    "done-no-icon": {
      note: "Done, with no icon found: the check alone, a little larger.",
      props: { preview: { ...done, icon: undefined } },
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
    close: {
      note: "A close: the card fades and scales down, then it is gone.",
      props: { preview: running },
      play: close,
    },
  },
});
