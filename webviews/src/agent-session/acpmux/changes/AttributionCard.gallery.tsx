// l10n-allow-file: gallery fixtures, not shipped UI.
// Who wrote a changed line: the marker on a hovered added line of a chat's edit diff and the card it
// shows, in three looks. A (`card`, ships): the glass hover card, the newest writer in full and
// older writers as compact rows under "Earlier". B (`line`): one caption line naming the newest
// writer only. C (`stack`): every writer in full with its chat's initials. A ships: it answers the
// question in one glance (which chat, model, prompt, when), keeps a second writer visible without
// doubling the card's height, and is the session hover card's geometry, so the two cards read as
// one family. B drops older writers and truncates the prompt to nothing on a narrow pane; C grows a
// full block per writer and repeats what A says in a row. Light and dark come from the gallery's
// color scheme switch.
// References (cmux-design-references index.json): cmux/live/history-machine-attribution-hover-preview,
// cmux/live/diffs-pr-card-popover, cmux/live/transcript-pr-hover-card-overlap,
// cmux/live/minimap-thread-hover-card.
import { componentEntry } from "../../../gallery/format";
import { FALLBACK_LINK_SCHEME, setLinkScheme } from "../links";
import type { Attribution } from "./attribution";
import { AttributionCardContent, type AttributionLook } from "./AttributionCard";

const NOW = Date.UTC(2026, 10, 9, 17, 0);
const MINUTE = 60_000;
const CURRENT = "chat-current";

const newest: Attribution = {
  start: 40,
  end: 44,
  sessionId: CURRENT,
  turnId: "turn-7",
  model: "Claude Opus 5.5",
  title: "Retry the upload with backoff",
  prompt: "Make the uploader retry with full jitter",
  at: NOW - 4 * MINUTE,
};
const older: Attribution = {
  start: 38,
  end: 42,
  sessionId: CURRENT,
  turnId: "turn-3",
  model: "Claude Sonnet 5",
  title: "Retry the upload with backoff",
  prompt: "Add a retry loop to the uploader",
  at: NOW - 3 * 60 * MINUTE,
};
const other: Attribution = {
  start: 12,
  end: 12,
  sessionId: "chat-other",
  turnId: "turn-2",
  model: "Claude Haiku 5",
  title: "Rename the settings keys",
  prompt: "Rename upload.retries to upload.maxRetries everywhere",
  at: NOW - 26 * 60 * MINUTE,
};
const long: Attribution = {
  ...newest,
  turnId: "turn-9",
  prompt:
    "Rewrite the uploader so that every failed chunk is retried with full jitter, the retry budget is shared across chunks of one file, and a cancelled upload stops its pending retries at once instead of waiting for the next tick",
};

type State = "one" | "two" | "other" | "long";
const WRITERS: Record<State, Attribution[]> = {
  one: [newest],
  two: [newest, older],
  other: [other, older],
  long: [long, other],
};

type Props = { look: AttributionLook; state: State };

/// A diff line's number gutter with the marker on it, and the card under it as it shows over the
/// transcript.
function AttributionStage({ look, state }: Props) {
  setLinkScheme(undefined, FALLBACK_LINK_SCHEME);
  return (
    <div className="acpmux-shell">
      <div data-attribution-fixture style={{ flex: 1, minWidth: 0, padding: 12 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, fontFamily: "var(--cv-mono)" }}>
          <span style={{ display: "flex", alignItems: "center", height: 20 }}>
            <button type="button" className="cv-attribution-marker" aria-label="Who wrote this line" />
            <span style={{ color: "var(--agent-muted)" }}>41</span>
          </span>
          <span>{"  await delay(jitter(attempt));"}</span>
        </div>
        <div
          className="ui-tooltip ui-card ui-glass ui-glass-floats cv-attribution-card"
          style={{ position: "static", width: "fit-content", marginTop: 8 }}
        >
          <AttributionCardContent
            writers={WRITERS[state]}
            currentSessionId={CURRENT}
            onReveal={() => undefined}
            look={look}
            now={NOW}
          />
        </div>
      </div>
    </div>
  );
}

const variants: Record<string, { note: string; props: Props }> = {};
const NOTES: Record<State, string> = {
  one: "one writer: a turn of this chat",
  two: "two turns wrote the line: the newest first, the older under it",
  other: "another chat wrote it: its title, and the row opens that chat's turn",
  long: "a long prompt is cut at two lines",
};
const LOOKS: Record<AttributionLook, string> = {
  card: "A (ships): glass card",
  line: "B: one-line tooltip",
  stack: "C: every writer in full with initials",
};
for (const look of ["card", "line", "stack"] as const)
  for (const state of ["one", "two", "other", "long"] as const)
    variants[`${look}-${state}`] = { note: `${LOOKS[look]}; ${NOTES[state]}.`, props: { look, state } };

export default componentEntry<Props>({
  id: "agent-pane.line-attribution",
  title: "Who wrote a line",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 320, normal: 560, wide: 760 },
  anchors: [{ selector: "[data-attribution-fixture]" }],
  keywords: ["blame", "attribution", "who wrote", "edit diff"],
  covers: ["agent-session/acpmux/changes/AttributionCard.tsx#AttributionCardContent"],
  styles: () => Promise.all([import("../styles.css"), import("./attribution.css")]),
  load: async () => AttributionStage,
  variants,
});
