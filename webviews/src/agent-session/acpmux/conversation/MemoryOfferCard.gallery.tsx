// l10n-allow-file: gallery fixtures (sample facts and errors), not shipped UI.
// The memory inbox card (MemoryOfferCard.tsx) in three looks: diff (shipped: `+` lines of a small
// diff with Accept and Dismiss always on each line), hover (the same diff, its actions only on the
// hovered or focused line) and checklist (a ticked box per fact and one Accept). Each look shows
// a live offer to click or key through (it settles after a short wait, as the daemon answers), a
// partly settled one whose write failed, a new file's single fact, and a settled card's note.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { MemoryOfferCard, type MemoryCardLook } from "./MemoryOfferCard";
import {
  memoryOfferFromRecord,
  memoryRequestFailed,
  memoryRequestStarted,
  settleMemoryOffer,
  type MemoryOffer,
} from "./memoryInbox";

const offer = (data: Record<string, unknown>) => memoryOfferFromRecord(data)!;

const LIVE = offer({
  offerId: "live",
  file: "CLAUDE.md",
  facts: [
    "Use bun, never npm.",
    "Run webview tests from webviews/ with bun test.",
    "Ask before pushing to a teammate's branch.",
  ],
  heading: "## Learned in chats",
  created: false,
});
const FAILED = memoryRequestFailed(
  settleMemoryOffer(
    offer({
      offerId: "failed",
      file: "AGENTS.md",
      facts: ["Format Rust with the pinned toolchain's rustfmt.", "Never edit generated settings files by hand."],
      heading: null,
      created: false,
    }),
    { accepted: ["Format Rust with the pinned toolchain's rustfmt."], dismissed: [] },
  ),
  [],
  "EACCES: permission denied, open 'AGENTS.md'",
);
const CREATED = offer({
  offerId: "created",
  file: "CLAUDE.md",
  facts: ["The staging database is read-only; use the local one for writes."],
  heading: "# Project notes",
  created: true,
});
const SETTLED = settleMemoryOffer(
  offer({ offerId: "settled", file: "CLAUDE.md", facts: ["A", "B", "C"], heading: null, created: false }),
  { accepted: ["A", "B"], dismissed: ["C"] },
);

/// An offer the gallery settles itself, after a wait like the daemon's write.
function LiveCard({ initial, look }: { initial: MemoryOffer; look: MemoryCardLook }) {
  const [state, setState] = useState(initial);
  return (
    <MemoryOfferCard
      offer={state}
      look={look}
      onResolve={(accept, dismiss) => {
        setState((current) => memoryRequestStarted(current, [...accept, ...dismiss]));
        setTimeout(
          () => setState((current) => settleMemoryOffer(current, { accepted: accept, dismissed: dismiss })),
          350,
        );
      }}
    />
  );
}

function MemoryLooks({ look }: { look: MemoryCardLook }) {
  return (
    <div className="acpmux-shell" style={{ padding: 16, display: "grid", gap: 16, alignContent: "start" }}>
      <LiveCard initial={LIVE} look={look} />
      <LiveCard initial={FAILED} look={look} />
      <LiveCard initial={CREATED} look={look} />
      <MemoryOfferCard offer={SETTLED} look={look} onResolve={() => {}} />
    </div>
  );
}

export default componentEntry<{ look: MemoryCardLook }>({
  id: "agent-pane.memory-offer",
  title: "Memory inbox card",
  area: "Agent pane",
  pane: true,
  height: 520,
  widths: { narrow: 420, normal: 640, wide: 820 },
  covers: ["agent-session/acpmux/conversation/MemoryOfferCard.tsx"],
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./MemoryOfferCard.gallery.css")]),
  load: async () => MemoryLooks,
  variants: {
    diff: {
      note: "Chosen: a small diff of the file, Accept and Dismiss always on each line; nothing to discover, one click or key per fact.",
      props: { look: "diff" },
    },
    hover: {
      note: "The same diff with each line's actions only on hover or focus; quieter at rest, but the card reads as inert until the pointer finds it.",
      props: { look: "hover" },
    },
    checklist: {
      note: "A ticked box per fact and one Accept for the ticked ones; two steps to drop one fact, and boxes hide that Accept writes a file.",
      props: { look: "checklist" },
    },
  },
});
