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
import { ComposerQueue } from "./ComposerQueue";
import { ConnectionChip } from "./HostError";
import { useT } from "./i18n";
import { MachineLinkStatus } from "./MachineLinkStatus";

/// `row`: an older row drawn above the composer beside the dot, to check it against its item (RFD
/// 0128, "the existing rows are left until each is checked against its item"): the automatic retry
/// line a rate limit's hold drew (now gone: the dot says it, with its reset), or the queue's paused
/// note (kept: it names the failed turn's error over the prompts it holds).
type Props = ComposerStatusDotProps & { before?: boolean; row?: "retry" | "queue" };

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

const sandbox: StatusItem = {
  kind: "harnessSandbox",
  level: "problem",
  words: "status.harnessSandbox.failing",
  subject: "Codex",
  since: NOW - 50_000,
};
const QUEUE = [
  { id: "q-1", prompt: "Then rebase the picker stack onto feat-cmux-next." },
  { id: "q-2", prompt: "Run the gallery for the composer status dot." },
];
const PAUSE_REASON = "API Error: 500 Internal server error";

/// The older rows, as the pane draws them: AutoResumeNotice's line (its markup, past its 10 s
/// quiet bound) and the real queue with its paused note.
function OldRow({ row }: { row: NonNullable<Props["row"]> }) {
  const t = useT();
  if (row === "retry")
    return (
      <output className="acpmux-switch-notice" data-auto-resume="waiting">
        {t("retry.waiting", { attempt: 1, of: 4 })}
      </output>
    );
  return (
    <div className="acpmux-composer-queue">
      <ComposerQueue chat="gallery" queue={QUEUE} paused pauseReason={PAUSE_REASON} t={t} onChange={async () => true} />
    </div>
  );
}

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

const ACTIONS = new Set(["reconnect", "resumeQueue"] as const);

// The composer stands at the pane's foot as in the dock, full width, so the card has the room above
// it that it opens into (side "top"), and the composer, an inline-size container, is never squeezed
// to its padding in the shell's row (which put the dot off the scene's left edge).
const SHELL = { padding: 16, flexDirection: "column", justifyContent: "flex-end" } as const;

function Row({ before = false, row, ...props }: Props) {
  return (
    <div className="acpmux-shell" data-composer-status-fixture style={SHELL}>
      {before ? <ConnectionChip kind="reconnecting" words="Reconnecting…" /> : null}
      {row ? <OldRow row={row} /> : null}
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
  "rate-limit-before": {
    note: "Before (#51343 as pushed): a rate limit's held retry drew the notice row's \"Retrying (1/4)\" over the transcript's foot and the dot's amber item, two places for one wait.",
    props: { items: [rateLimited], row: "retry", initial: "pinned" },
  },
  "rate-limit-after": {
    note: 'Picked: the row is gone; the dot\'s card says the hold and its reset ("Rate limited until …"), which the row never did. Capacity and connection retries keep their row: they have no item.',
    props: { items: [rateLimited], initial: "pinned" },
  },
  "queue-paused-kept": {
    note: "Kept: the queue's paused note names the failed turn's error over the prompts it holds, which an item cannot carry (its words are a catalog key). Both Resume buttons make the same call (queuePause.ts resumeQueue).",
    props: { items: [queuePaused], row: "queue", initial: "pinned" },
  },
  "stuck-sandbox": {
    note: "Nothing to remove: no pane row ever drew stuckReason or harnessSandboxFailing; the dot is their first surface. Each failed turn keeps its own error card in the transcript.",
    props: { items: [stuck, sandbox], initial: "pinned" },
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
