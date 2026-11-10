// l10n-allow-file: gallery fixtures (sample presets, hosts and errors), not shipped UI.
// The no-prompt preset approval card (PresetApprovalCard.tsx) in three looks: card (shipped: the
// question over what it starts and the warning, Not now and Approve at its foot), inline (the
// buttons beside the question, the warning below) and details (what it starts as a label and value
// table). Each look shows an open card to click (it closes after a short wait, as acpmux answers),
// one acpmux refused (the preset changed since it was drawn), an approved card's note and a
// declined card's note.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { PresetApprovalCard, type PresetApprovalLook } from "./PresetApprovalCard";
import {
  presetApprovalAsk,
  presetApprovalClosed,
  presetApprovalFailed,
  presetApprovalSending,
  type PresetApproval,
} from "./presetApproval";

const ask = (data: Record<string, unknown>) => presetApprovalAsk(data)!;

const OPEN: PresetApproval = {
  ask: ask({
    preset: "lane",
    digest: "9f2c",
    harness: "claude",
    model: "opus",
    effort: "high",
    policy: "approve-all",
    host: "build-linux-3",
    description: "Lane agent for fleet compile checks",
  }),
};
const FAILED = presetApprovalFailed(
  presetApprovalSending(
    {
      ask: ask({ preset: "nightly-fix", digest: "71ab", harness: "codex", policy: "approve-all", host: "gcp-lane-2" }),
    },
    "approved",
  ),
  "preset nightly-fix changed since this card was shown: approve it again from the new card",
);
const APPROVED = presetApprovalClosed(OPEN, "approved");
const DECLINED = presetApprovalClosed(
  { ask: ask({ preset: "triage", digest: "c0de", harness: "claude", model: "sonnet", policy: "approve-reads" }) },
  "declined",
);

/// A card the gallery answers itself, after a wait like acpmux's.
function LiveCard({ initial, look }: { initial: PresetApproval; look: PresetApprovalLook }) {
  const [state, setState] = useState(initial);
  return (
    <PresetApprovalCard
      approval={state}
      look={look}
      onAnswer={(outcome) => {
        setState((current) => presetApprovalSending(current, outcome));
        setTimeout(() => setState((current) => presetApprovalClosed(current, outcome)), 350);
      }}
    />
  );
}

function PresetApprovalLooks({ look }: { look: PresetApprovalLook }) {
  return (
    <div
      className="acpmux-shell"
      data-preset-approval-fixture
      style={{ padding: 16, display: "grid", gap: 16, alignContent: "start" }}
    >
      <LiveCard initial={OPEN} look={look} />
      <LiveCard initial={FAILED} look={look} />
      <PresetApprovalCard approval={APPROVED} look={look} onAnswer={() => {}} />
      <PresetApprovalCard approval={DECLINED} look={look} onAnswer={() => {}} />
    </div>
  );
}

export default componentEntry<{ look: PresetApprovalLook }>({
  id: "agent-pane.preset-approval",
  title: "No-prompt preset approval card",
  area: "Agent pane",
  pane: true,
  height: 560,
  widths: { narrow: 420, normal: 640, wide: 820 },
  anchors: [{ selector: "[data-preset-approval-fixture]" }],
  covers: ["agent-session/acpmux/conversation/PresetApprovalCard.tsx"],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  load: async () => PresetApprovalLooks,
  variants: {
    card: {
      note: "Chosen: the memory card's box, the question over what it starts and the warning, Not now and Approve at the foot; the warning sits right above the buttons, so it is read before the click, and narrow panes never squeeze the text.",
      props: { look: "card" },
    },
    inline: {
      note: "The buttons beside the question in one compact box; shorter, but at 420px the question wraps beside them and the warning ends up below the buttons.",
      props: { look: "inline" },
    },
    details: {
      note: "What it starts as an Agent / Policy / Machine table; easy to scan, but a taller card for three short values, and it reads as a settings form more than a question.",
      props: { look: "details" },
    },
  },
});
