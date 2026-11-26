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
import { ConnectionChip } from "./HostError";
import { MachineLinkStatus } from "./MachineLinkStatus";

type Props = ComposerStatusDotProps & { before?: boolean };

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

// A chat on another machine, as acpmux marks it: its machine earns its name at rest.
const remoteFacts: FooterFact[] = facts.map((fact) => (fact.kind === "machine" ? { ...fact, atRest: true } : fact));
const quietRemoteFacts = remoteFacts.filter((fact) => !fact.live);

const ACTIONS = new Set(["reconnect", "resumeQueue"] as const);

// The composer stands at the pane's foot as in the dock, full width, so the card has the room above
// it that it opens into (side "top"), and the composer, an inline-size container, is never squeezed
// to its padding in the shell's row (which put the dot off the scene's left edge).
const SHELL = { padding: 16, flexDirection: "column", justifyContent: "flex-end" } as const;

function Row({ before = false, ...props }: Props) {
  return (
    <div className="acpmux-shell" data-composer-status-fixture style={SHELL}>
      {before ? <ConnectionChip kind="reconnecting" words="Reconnecting…" /> : null}
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
            <ComposerStatusDot
              now={NOW}
              arm="off"
              machineAtRest="off"
              actions={ACTIONS}
              onAction={() => undefined}
              {...props}
            />
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
  "machine-at-rest-off": {
    note: "Switch composer-machine-at-rest off (the default, as shipped): a connected remote chat at rest is the green dot alone.",
    props: { items: [], connectedTo: MACHINE, facts: quietRemoteFacts },
  },
  "machine-at-rest-name": {
    note: "Switch on: a chat on another machine keeps its machine's name beside the dot at rest (acpmux marks the fact atRest); a click on it pins the card.",
    props: { items: [], connectedTo: MACHINE, facts: quietRemoteFacts, machineAtRest: "on" },
  },
  "machine-at-rest-name-counters": {
    note: "Switch on with facts arm pulse: the name, then the live counters (subagents, queued 9+); the name is cut before it can push the model chip.",
    props: { items: [], connectedTo: MACHINE, facts: remoteFacts, arm: "pulse", machineAtRest: "on" },
  },
  "machine-at-rest-offline": {
    note: "Switch on while the link is down: the dot takes the item's ink, and the name stays where it was, so nothing moves.",
    props: { items: [offline], facts: quietRemoteFacts, machineAtRest: "on" },
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
