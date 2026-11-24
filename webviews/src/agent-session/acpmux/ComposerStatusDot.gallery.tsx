// l10n-allow-file: gallery fixtures (machine, folder and model names), not shipped UI.
// The composer status dot (ComposerStatusDot.tsx; Leo, 2026-11-22: "some sort of status dot that
// fades in and when you hover or click into it ... give you rundowns of various statuses"). Before,
// the pane's "Reconnecting…" chip sat in a slot over the transcript's end and drew over its text, and
// the machine row spelled each link state out (`before`). The dot keeps one 6px box in the footer,
// tinted by the worst item; its card lists them. Picked look: the plain dot. Alternates (not shipped):
// `dot-count` (a count beside the dot) and `glyph` (a warning glyph on a problem).
import { componentEntry } from "../../gallery/format";
import { ComposerStatusDot, type ComposerStatusDotProps } from "./ComposerStatusDot";
import type { FooterFact, StatusItem } from "./composerStatusModel";
import { ConnectionChip, HostUnavailableLine } from "./HostError";
import { MachineLinkStatus } from "./MachineLinkStatus";

/// `hostCard`: the host failure card (HostError.tsx HostUnavailableLine) over the composer, as before
/// RFD 0128 moved it into the dot.
type Props = ComposerStatusDotProps & { before?: boolean; hostCard?: boolean };

const NOW = Date.UTC(2026, 10, 22, 22, 40);
const MACHINE = "walk-remote";

const reconnecting: StatusItem = {
  kind: "machineLink",
  level: "info",
  words: "status.machineLink.reconnecting",
  subject: MACHINE,
  since: NOW - 40_000,
};
const rateLimited: StatusItem = {
  kind: "rateLimited",
  level: "attention",
  words: "status.rateLimited.until",
  subject: "Claude Code",
  since: NOW - 120_000,
  until: NOW + 25 * 60_000,
};
const offline: StatusItem = {
  kind: "machineLink",
  level: "attention",
  words: "status.machineLink.offline",
  subject: MACHINE,
  since: NOW - 90_000,
  action: "reconnect",
};
const stuck: StatusItem = {
  kind: "stuck",
  level: "problem",
  words: "status.stuck.spawnFailed",
  subject: "Codex",
  since: NOW - 30_000,
};
const queuePaused: StatusItem = {
  kind: "queuePaused",
  level: "attention",
  words: "status.queuePaused.paused",
  since: NOW - 60_000,
  action: "resumeQueue",
};

const HOST_DETAIL = "acpmux: connect /run/acpmux.sock: connection refused (os error 111)";
const hostFailure: StatusItem = {
  kind: "hostFailure",
  level: "problem",
  words: "status.hostFailure.unavailable",
  since: NOW - 45_000,
  detail: HOST_DETAIL,
  action: "retry",
};
const peerFailure: StatusItem = {
  ...hostFailure,
  words: "status.hostFailure.peerUnreachable",
  subject: MACHINE,
  action: "restartService",
};
const hostReconnecting: StatusItem = {
  kind: "agentService",
  level: "info",
  words: "status.agentService.reconnecting",
};

const facts: FooterFact[] = [
  { kind: "machine", text: MACHINE, live: false },
  { kind: "folder", text: "/Users/leo/Projects/cmux/webviews", live: false },
  { kind: "branch", text: "lane/composer-status-dot", live: false },
  { kind: "model", text: "opus", live: false },
  { kind: "context", fraction: 0.42, live: false },
  { kind: "turn", since: NOW - 95_000, live: false },
  { kind: "subagents", count: 3, live: true },
  { kind: "queued", count: 12, live: true },
];

const ACTIONS = new Set(["reconnect", "resumeQueue", "retry", "restartService"] as const);

// The composer stands at the pane's foot as in the dock, full width, so the card has the room above
// it that it opens into (side "top"), and the composer, an inline-size container, is never squeezed
// to its padding in the shell's row (which put the dot off the scene's left edge).
const SHELL = { padding: 16, flexDirection: "column", justifyContent: "flex-end" } as const;

function Row({ before = false, hostCard = false, ...props }: Props) {
  return (
    <div className="acpmux-shell" data-composer-status-fixture style={SHELL}>
      {before ? <ConnectionChip kind="reconnecting" words="Reconnecting…" /> : null}
      {hostCard ? (
        <HostUnavailableLine
          message="Can't reach the agent service."
          detail={HOST_DETAIL}
          selfRetrying={false}
          onRetry={() => undefined}
        />
      ) : null}
      <form className="acpmux-composer">
        <div className="acpmux-composer-bar acpmux-composer-foot" data-footer-look="plain">
          <span className="acpmux-chips">
            <span className="acpmux-access">
              <button type="button" className="acpmux-picker-button">
                Normal
              </button>
            </span>
            <span className="acpmux-model">
              <button type="button" className="acpmux-picker-button">
                <span className="acpmux-model-name">opus</span>
              </button>
            </span>
          </span>
          {before ? (
            <MachineLinkStatus
              link={{ machine: MACHINE, link: "connecting", reconnecting: true }}
              quietMs={0}
              onReconnect={() => undefined}
            />
          ) : (
            <ComposerStatusDot now={NOW} arm="off" actions={ACTIONS} onAction={() => undefined} {...props} />
          )}
        </div>
      </form>
    </div>
  );
}

const variants: Record<string, { note: string; props: Props }> = {
  before: {
    note: "Before: \"Reconnecting…\" in the slot over the transcript's end, and the machine row's spelled-out state. Not picked: it drew over text.",
    props: { items: [], before: true },
  },
  "resting-remote": {
    note: "Picked: a connected remote chat with nothing to say keeps the success-green dot, as the machine row did.",
    props: { items: [], connectedTo: MACHINE },
  },
  info: {
    note: "Picked: an info item (the link coming back) tints the dot muted; no spinner, no words.",
    props: { items: [reconnecting] },
  },
  attention: {
    note: "Picked: an attention item (a rate limit) tints the dot amber.",
    props: { items: [rateLimited] },
  },
  problem: {
    note: "Picked: a problem (the agent did not start) tints the dot red and is announced once.",
    props: { items: [stuck] },
  },
  many: {
    note: "Picked: three items, one dot at the worst level; the card lists them worst first.",
    props: { items: [offline, stuck, queuePaused], initial: "pinned" },
  },
  peek: {
    note: "Picked: a hover peeks the card; its key hint's line is kept empty so pinning never resizes it.",
    props: { items: [offline, rateLimited], initial: "peek" },
  },
  pinned: {
    note: "Picked: a click pins the same card, adding only esc Close; its actions are one quiet button each.",
    props: { items: [offline, rateLimited], initial: "pinned" },
  },
  "dot-count": {
    note: "Not picked: a count beside the dot reads as unread messages and widens the box.",
    props: { items: [offline, stuck, queuePaused], look: "count" },
  },
  glyph: {
    note: "Not picked: a warning glyph on a problem says the same as the red, louder than unobtrusive.",
    props: { items: [stuck], look: "glyph" },
  },
  "host-before": {
    note: "Before (RFD 0128 follow-up): the host failure card stood over the transcript's end with Retry and Details, taking the composer's top.",
    props: { items: [], hostCard: true },
  },
  "host-failure": {
    note: "Picked: the same failure is a problem item; the red dot is announced once and its card keeps Retry and Details.",
    props: { items: [hostFailure], initial: "pinned" },
  },
  "host-details": {
    note: "Picked: Details opens the service's own words under the row, selectable for copying.",
    props: { items: [hostFailure], initial: "pinned", initialDetail: "hostFailure" },
  },
  "host-restarting": {
    note: "Picked: a remote machine's service offers Restart; while it runs the button says Restarting… and is disabled.",
    props: { items: [{ ...peerFailure, pending: true }], initial: "pinned" },
  },
  "host-reconnecting": {
    note: "Picked: while the pane retries by itself, the old Reconnecting… chip is a muted info item instead.",
    props: { items: [hostReconnecting], initial: "peek" },
  },
  "facts-pulse": {
    note: "Experiment arm pulse: the card's Session list, and live counters (subagents, queued 9+) beside the dot.",
    props: { items: [], connectedTo: MACHINE, facts, arm: "pulse", initial: "pinned" },
  },
  "facts-door": {
    note: "Experiment arm door: a faint resting dot on this Mac whose card holds the Session list only.",
    props: { items: [], facts, arm: "door", initial: "pinned" },
  },
  "facts-strip": {
    note: "Experiment arm strip: one low-contrast line in the free middle (machine, folder, branch, context, turn) and the live counters; the cut-off path at narrow widths is why it is not the pick.",
    props: { items: [], connectedTo: MACHINE, facts, arm: "strip" },
  },
};

export default componentEntry<Props>({
  id: "agent-pane.composer-status-dot",
  title: "Composer status dot",
  area: "Agent pane",
  height: 280,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: "[data-composer-status-fixture]" }],
  covers: [
    "agent-session/acpmux/ComposerStatusDot.tsx#ComposerStatusDot",
    "agent-session/acpmux/ComposerStatusDot.tsx#ComposerStatusFoot",
    "agent-session/acpmux/composerStatusCard.tsx#StatusCard",
  ],
  pane: true,
  load: async () => Row,
  variants,
});
