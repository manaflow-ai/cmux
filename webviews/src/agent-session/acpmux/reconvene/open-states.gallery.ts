// l10n-allow-file: gallery fixtures, not shipped UI.
// Reconvene item `open-states`: between a click and the chat, the moments that still show a loading
// state: a slow attach, a paused or resuming Cloud chat, a reconnecting host. Since #39887 the last
// frame stays until the chat is ready (firstPaint.ts) and #37761 fades the first rows in
// (shared/loadFade.ts); what is left is the reconnecting machine's spinner, drawn as a line under the
// header over the rows last read (ChatUnavailableState `line`) or, with no rows, as the centred 28px
// spinner card.
// Leo, 2026-11-09: "When this loads ... It shows me a glimpse of the past thing, and then it regresses
// into the skeletons and placeholders, and then it gets back to the true thing. So I feel like the
// intermediate steps, we can just, like, not bother trying to show them, because it's just super
// jarring and it's not useful." Leo, 2026-11-07: "going from blank to text is more jarring than blank
// to fast fade in to text".
// Spec: leo-workspace design/chat-transcript.md (an opened chat draws its newest local transcript at
// once; a remote copy draws before the connection), design/motion-and-polish.md (working is a
// spinner, nothing else animates for waiting), the cmux pane spec
// plans/cmux-next/spec-proposals/visuals/components/agent-pane.md.
// Refs: cmux/live/status-reconnecting-indicator-lingers (Leo: the "Reconnecting..." spinner and Retry
// are unnecessary and linger), cmux/live/status-same-session-two-panes-socket-block (a body banner and
// a header "Reconnecting" saying the same thing twice), claude/live/composer-model-effort-footer-row
// (a quiet working mark in the composer's own line, not in the transcript).
// The state is put in place by the snapshot alone: a Cloud chat's machine is not connected
// (`unavailable: offline`), the tab names the chat (`missingSession`) and the Mac's copy of its rows is
// drawn (direct.ts drawMissingTail), as after a relaunch while the machine reconnects. The `-cold`
// variants are the same moment with no rows read yet.
import { GALLERY_NOW } from "../../../gallery/clock";
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, chat, session, SESSION_ID, user } from "../../../gallery/fixtures/acpmux";
import { arms, showArm, type Arm } from "./arm";

const PEER = "dev-vm-2";
const peerSession = session({
  sessionId: SESSION_ID,
  title: "Retry the flaky upload test",
  host: PEER,
  hostKind: "cloud",
});
const unavailable = {
  reason: "offline" as const,
  machine: PEER,
  lastSeen: GALLERY_NOW - 2 * 60_000,
};

const rows = () => [
  user("The upload test fails about one run in ten. Find out why and fix it.", 48),
  assistant(
    "The test races the progress callback: it asserts on the final byte count before the last chunk's callback runs. I made the assertion wait for the upload's completion event and ran it 200 times with no failure.",
    46,
  ),
  user("Good. Open a PR with that.", 40),
  assistant("Opened the PR with the fix and a note on the race in its description.", 39),
];

/// The tab's chat while its machine reconnects: the rows last read (or none), the chat not listed yet.
const reconnecting = (held: boolean) => {
  const snapshot = chat(held ? rows() : [], {
    title: "Retry the flaky upload test",
    sessions: [peerSession],
    unavailable,
    missingSession: SESSION_ID,
  });
  return {
    ...snapshot,
    sessionId: undefined,
    summary: {
      ...snapshot.summary!,
      host: PEER,
      peer: PEER,
      hostKind: "cloud" as const,
    },
  };
};

/// What says the chat is reconnecting: the line over held rows, or the centred card.
const SAID = ':is(.acpmux-unavailable-line, .acpmux-unavailable[data-unavailable="offline"])';
const LINE = ".acpmux-stage > .acpmux-unavailable-line";
const CARD = '.acpmux-stage > .acpmux-unavailable[data-unavailable="offline"]';

/// Puts the pane in the moment and draws `arm`; the composer-line arm reads the line's own words
/// (the pane's translated title) into its note, so no copy is invented here.
async function reconnectingMoment(ctx: PlayContext, arm?: Arm) {
  await ctx.waitFor(() => ctx.document.querySelector(`.acpmux-stage > ${SAID}`));
  const title = ctx.document.querySelector(
    ".acpmux-unavailable-line .acpmux-peer-copy-title, .acpmux-unavailable-title",
  );
  ctx.document.documentElement.style.setProperty("--reconvene-open-note", JSON.stringify(title?.textContent ?? ""));
  if (arm) await showArm(ctx, arm);
}

/// The delayed note's fade has run (it starts about a second after the state appears).
const noteShown = (ctx: PlayContext) =>
  ctx.waitFor(() =>
    ctx.document
      .getAnimations()
      .filter((animation) => (animation as CSSAnimation).animationName === "reconvene-open-note-in")
      .every((animation) => animation.playState === "finished"),
  );

export const ARMS = arms({
  /// The rows (or the empty transcript) hold still; the header's status slot alone says
  /// "Reconnecting…", muted, in the status label's type (header.css .acpmux-status). No spinner, no
  /// detail and no buttons in the body.
  "hold-frame": {
    css: `
${LINE}, ${CARD} > .acpmux-unavailable-title {
  position: absolute;
  top: 0;
  left: var(--ds-space-2);
  right: auto;
  z-index: var(--layer-raised, 1);
  display: flex;
  align-items: center;
  height: var(--acpmux-header-height);
  margin: 0;
  padding: 0;
  pointer-events: none;
}
${CARD} {
  position: static;
}
${LINE} :is(.acpmux-peer-copy-spinner, .acpmux-watch-hint, .acpmux-unavailable-actions),
${CARD} > :not(.acpmux-unavailable-title),
${CARD} .acpmux-unavailable-copy > * {
  display: none;
}
${LINE} .acpmux-peer-copy-title, ${CARD} > .acpmux-unavailable-title {
  color: var(--agent-muted);
  font-size: var(--text-detail);
  font-weight: inherit;
  line-height: var(--text-detail--line-height);
  letter-spacing: var(--text-detail--letter-spacing);
}`,
    ready: `.acpmux-stage > ${SAID}`,
  },
  /// Nothing in the body: one indeterminate accent hairline runs along the transcript's top edge,
  /// under the header, until the chat is back.
  "edge-progress": {
    css: `
${LINE}, ${CARD} > * {
  display: none;
}
${CARD} {
  visibility: hidden;
}
.acpmux-stage:has(> ${SAID})::after {
  content: "";
  position: absolute;
  top: var(--acpmux-header-height);
  left: 0;
  right: 0;
  z-index: var(--layer-raised, 1);
  height: 2px;
  pointer-events: none;
  background: linear-gradient(to right, transparent, var(--agent-accent), transparent) no-repeat;
  background-size: 40% 100%;
  background-position: -40% 0;
  animation: reconvene-open-edge calc(var(--cmux-motion-large) * 6) linear infinite;
}
@keyframes reconvene-open-edge {
  from { background-position: -40% 0; }
  to { background-position: 140% 0; }
}
@media (prefers-reduced-motion: reduce) {
  .acpmux-stage:has(> ${SAID})::after {
    animation: none;
    background: color-mix(in srgb, var(--agent-accent) 40%, transparent);
  }
}`,
    ready: `.acpmux-stage > ${SAID}`,
  },
  /// Nothing for about a second, then one muted line in the composer's top line (where the remote
  /// note sits, styles.css .acpmux-composer-remote-note) in the line's own words.
  "delayed-note": {
    css: `
${LINE}, ${CARD} > * {
  display: none;
}
${CARD} {
  visibility: hidden;
}
.acpmux-main:has(> .acpmux-stage > ${SAID}) > .acpmux-dock > .acpmux-composer::before {
  content: var(--reconvene-open-note);
  display: block;
  flex: 0 0 100%;
  margin: 0 0 var(--ds-space-1);
  color: var(--agent-muted);
  font-size: var(--text-detail);
  line-height: var(--text-detail--line-height);
  letter-spacing: var(--text-detail--letter-spacing);
  animation: reconvene-open-note-in var(--agent-motion-in) var(--cmux-ease-out) both;
  animation-delay: calc(var(--cmux-motion-large) * 4);
}
@keyframes reconvene-open-note-in {
  from { opacity: 0; }
  to { opacity: 1; }
}`,
    ready: `.acpmux-stage > ${SAID}`,
  },
});

export default agentPaneEntry({
  id: "agent-pane.reconvene-open-states",
  title: "Reconvene: between a click and the chat",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/ChatUnavailableState.tsx#ChatUnavailableState", "agent-session/acpmux/firstPaint.ts"],
  variants: {
    now: {
      note: "Shipped: over the rows last read, a line under the header with a spinner, 'Reconnecting…', when the machine was last seen, and Reconnect, Resume from Transcript and Close Tab.",
      snapshot: reconnecting(true),
      play: (ctx) => reconnectingMoment(ctx),
    },
    "now-cold": {
      note: "Shipped, no rows read yet: the centred 28px spinner card with the same words and buttons in place of the transcript.",
      snapshot: reconnecting(false),
      play: (ctx) => reconnectingMoment(ctx),
    },
    "hold-frame": {
      note: "The rows hold; the header's status slot alone says 'Reconnecting…', muted, no spinner. Trade-off: Reconnect and Close Tab leave the body (the header menu has them), so a stuck machine is one click further.",
      snapshot: reconnecting(true),
      play: (ctx) => reconnectingMoment(ctx, ARMS["hold-frame"]),
    },
    "hold-frame-cold": {
      note: "hold-frame with no rows read: an empty transcript and the header's words; nothing in the body.",
      snapshot: reconnecting(false),
      play: (ctx) => reconnectingMoment(ctx, ARMS["hold-frame"]),
    },
    "edge-progress": {
      note: "Nothing in the body; an indeterminate accent hairline along the transcript's top edge. Trade-off: motion that says 'busy' with no words, so a long wait never says why or offers Reconnect.",
      snapshot: reconnecting(true),
      play: (ctx) => reconnectingMoment(ctx, ARMS["edge-progress"]),
    },
    "edge-progress-cold": {
      note: "edge-progress with no rows read: an empty transcript under the moving hairline.",
      snapshot: reconnecting(false),
      play: (ctx) => reconnectingMoment(ctx, ARMS["edge-progress"]),
    },
    "delayed-note": {
      note: "Nothing for about a second, then one muted 'Reconnecting…' line in the composer's top line (shown settled). Trade-off: the note sits where the eye already is, but the composer moves up one line when it comes.",
      snapshot: reconnecting(true),
      play: async (ctx) => {
        await reconnectingMoment(ctx, ARMS["delayed-note"]);
        await noteShown(ctx);
      },
    },
    "delayed-note-cold": {
      note: "delayed-note with no rows read: an empty transcript, and the note over the composer after a second.",
      snapshot: reconnecting(false),
      play: async (ctx) => {
        await reconnectingMoment(ctx, ARMS["delayed-note"]);
        await noteShown(ctx);
      },
    },
  },
});
