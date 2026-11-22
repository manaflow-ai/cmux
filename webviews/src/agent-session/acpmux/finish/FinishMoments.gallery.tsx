// l10n-allow-file: gallery fixtures, not shipped UI.
// The chat's finish moments (finishMoments.ts) on the real header PR chip, three looks each. The
// shipped look is `ring` for green checks and `burst` for a merge; the others are the looks it was
// chosen over. A turn's end draws nothing on "Worked for" (Lucas, 2026-11-14: Codex has no flash).
// Light and dark come from the stage.
import { useEffect, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { HeaderPullRequest } from "../header/headerState";
import { PullRequestChip } from "../header/PullRequestChip";
import { endFinishMoment, startFinishMoment, type FinishKind } from "./finishMoments";

type Look = "tint" | "ring" | "dot-check" | "burst" | "glow" | "stamp";
type Props = { kind: Exclude<FinishKind, "turn">; look: Look; reduced?: boolean };

const pullRequest = (kind: Props["kind"]): HeaderPullRequest => ({
  url: "https://github.com/example/app/pull/482",
  number: 482,
  title: "Retry uploads that time out",
  state: kind === "merged" ? "merged" : "open",
  review: "approved",
  mergeable: "mergeable",
  checks: { state: "passing", passed: 12, total: 12 },
  checkList: [],
});

function FinishMomentsGallery({ kind, look, reduced = false }: Props) {
  const [plays, setPlays] = useState(0);
  // Reduce Motion is read from the root, as the app's switch sets it.
  useEffect(() => {
    const root = document.documentElement;
    if (!reduced) return;
    const before = root.dataset.agentMotion;
    root.dataset.agentMotion = "reduced";
    return () => {
      if (before === undefined) delete root.dataset.agentMotion;
      else root.dataset.agentMotion = before;
    };
  }, [reduced]);
  // Plays on open and on each Replay; the moment's own timer ends it.
  useEffect(() => {
    startFinishMoment({ kind, session: "gallery", url: pullRequest(kind).url });
    return endFinishMoment;
  }, [kind, plays]);
  return (
    <div className="acpmux-finish-stage" data-finish-look={look} data-gallery-capture="">
      <div className="acpmux-finish-stage__header">
        <span className="acpmux-finish-stage__title">Retry uploads that time out</span>
        <PullRequestChip pullRequest={pullRequest(kind)} />
      </div>
      <button type="button" className="acpmux-finish-stage__replay" onClick={() => setPlays((n) => n + 1)}>
        Replay
      </button>
    </div>
  );
}

const replay: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Replay" });
  await ctx.waitFor(() => document.querySelector("[data-finish]"));
};

export default componentEntry<Props>({
  id: "agent-pane.finish-moments",
  title: "Finish moments",
  area: "Agent pane",
  height: 180,
  covers: ["agent-session/acpmux/finish/finishMoments.ts", "agent-session/acpmux/finish/FinishBurst.tsx#FinishBurst"],
  load: async () => FinishMomentsGallery,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("../header/header.css"),
      import("./finish.css"),
      import("./FinishMoments.gallery.css"),
    ]),
  variants: {
    "ci-ring": {
      props: { kind: "ci", look: "ring" },
      note: "Shipped. The checks dot turns green and sends out one ring.",
      play: replay,
    },
    "ci-tint": {
      props: { kind: "ci", look: "tint" },
      note: "The chip's text green alone, with no mark to find it by.",
    },
    "ci-dot-check": {
      props: { kind: "ci", look: "dot-check" },
      note: "The dot grows into a check: crowds the number at 6 px.",
    },
    "merged-burst": {
      props: { kind: "merged", look: "burst" },
      note: "Shipped, the bigger moment. The chip turns purple, rises 8% and ten dots burst from it, done by 950 ms.",
      play: replay,
    },
    "merged-glow": {
      props: { kind: "merged", look: "glow" },
      note: "A purple ring and the rise: calm, but no bigger than green checks.",
    },
    "merged-stamp": {
      props: { kind: "merged", look: "stamp" },
      note: "A stamp-in from 1.3x: a large fly-in for a 20 px chip.",
    },
    "merged-reduced": {
      props: { kind: "merged", look: "burst", reduced: true },
      note: "Reduce Motion: the purple chip, still; no dots.",
    },
  },
});
