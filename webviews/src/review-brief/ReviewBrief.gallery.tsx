// l10n-allow-file: gallery fixtures (a sample chat's brief), not shipped UI.
// The diff viewer's review brief: the landed design (a row under the toolbar, kept from the first
// frame, opening a panel over the diff) in each state, and the two placements it was chosen over.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import type { ReviewBrief } from "./model";
import { ReviewBriefBody, ReviewBriefStrip, type ReviewBriefLabels, type ReviewBriefState } from "./ReviewBrief";

const LABELS: ReviewBriefLabels = {
  title: "Brief",
  loading: "Reading the chat…",
  failed: "The chat's brief could not be read.",
  empty: "No plan, dropped approaches or unsure spots in this chat.",
  goal: "Set out to",
  plan: "Plan",
  rejected: "Tried and dropped",
  unsure: "Unsure about",
  show: "Show brief",
  hide: "Hide brief",
  hedge: "Hedged",
  reverted: "Undone",
  redone: "Undone, then redone",
  reworked: "Rewritten",
  notInDiff: "Not in this diff",
};

// The fixture chat of acpmux `review_brief_fixtures/claude.ndjson`, as its brief reads.
const BRIEF: ReviewBrief = {
  goal: "Make the uploader retry failed chunks with backoff, and keep the progress bar honest.",
  planText: "Retry each chunk; clamp progress.",
  plan: [
    { content: "Find where chunks are sent", status: "completed" },
    { content: "Add retry with backoff", status: "completed" },
    { content: "Test the progress bar", status: "pending" },
  ],
  rejected: [
    {
      text: "I first tried wrapping the whole upload in a retry loop, but that didn't work because it restarts finished chunks.",
      seq: 4,
    },
  ],
  unsure: [
    { kind: "redone", text: "", path: "src/upload.rs", snippet: "retry(|| send(chunk))?;", count: 0, seq: 9 },
    {
      kind: "hedge",
      text: "I'm not sure the backoff cap in upload.rs is right for slow links.",
      path: "src/upload.rs",
      snippet: "",
      count: 0,
      seq: 11,
    },
    {
      kind: "hedge",
      text: "The progress clamp is untested on resumed uploads.",
      path: "src/progress.rs",
      snippet: "",
      count: 0,
      seq: 11,
    },
    { kind: "reworked", text: "", path: "src/cfg.py", snippet: "def load_config(path=None):", count: 2, seq: 14 },
  ],
};

type Design = "strip" | "sidebar" | "inline";
type Props = { design?: Design; state?: "loading" | "ready" | "empty" | "failed"; open?: boolean };

const stateOf = (state: Props["state"]): ReviewBriefState =>
  state === "loading"
    ? { kind: "loading" }
    : state === "failed"
      ? { kind: "failed" }
      : state === "empty"
        ? { kind: "ready", brief: { goal: "", planText: "", plan: [], rejected: [], unsure: [] } }
        : { kind: "ready", brief: BRIEF };

/** Stand-in file rows, so the panel is seen over a diff and the placements compare fairly. */
function StandInDiff() {
  return (
    <div style={{ padding: 12, display: "flex", flexDirection: "column", gap: 8 }}>
      {["src/upload.rs", "src/progress.rs", "src/cfg.py"].map((name) => (
        <div
          key={name}
          style={{ height: 88, borderRadius: 6, background: "var(--cmux-diff-muted-bg)", padding: "4px 8px" }}
        >
          <code style={{ fontSize: "var(--cmux-diff-font-size)", color: "var(--cmux-diff-text-muted)" }}>{name}</code>
        </div>
      ))}
    </div>
  );
}

function ReviewBriefStage({ design = "strip", state = "ready", open = false }: Props) {
  const [shown, setShown] = useState(open);
  const brief = stateOf(state);
  if (design === "sidebar") {
    return (
      <div style={{ display: "flex", height: "100%" }}>
        <aside
          style={{
            width: 280,
            overflow: "auto",
            padding: 12,
            background: "var(--cmux-diff-files-bg)",
            borderRight: "0.5px solid var(--cmux-diff-border)",
          }}
        >
          {brief.kind === "ready" ? (
            <ReviewBriefBody brief={brief.brief} labels={LABELS} onOpenSpot={() => {}} />
          ) : null}
        </aside>
        <div style={{ flex: 1 }}>
          <StandInDiff />
        </div>
      </div>
    );
  }
  if (design === "inline") {
    return (
      <div style={{ height: "100%", overflow: "auto" }}>
        <div style={{ margin: 12, padding: 12, borderRadius: 8, background: "var(--cmux-diff-muted-bg)" }}>
          {brief.kind === "ready" ? (
            <ReviewBriefBody brief={brief.brief} labels={LABELS} onOpenSpot={() => {}} />
          ) : null}
        </div>
        <StandInDiff />
      </div>
    );
  }
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      <ReviewBriefStrip state={brief} labels={LABELS} open={shown} onOpenChange={setShown} onOpenSpot={() => {}} />
      <StandInDiff />
    </div>
  );
}

export default componentEntry<Props>({
  id: "diff.review-brief",
  title: "Diff: review brief",
  area: "Pages",
  height: 520,
  widths: { normal: 720, narrow: 420 },
  covers: ["review-brief/ReviewBrief.tsx"],
  styles: () => import("../styles.css"),
  load: async () => ReviewBriefStage,
  variants: {
    "strip-closed": {
      props: { design: "strip", state: "ready" },
      note: "Landed: one row under the toolbar names the goal and counts the unsure spots. Click opens the panel.",
    },
    "strip-open": {
      props: { design: "strip", state: "ready", open: true },
      note: "Landed, open: the panel lies over the diff and never moves it. Unsure spots come first; each opens its hunk.",
    },
    "strip-loading": {
      props: { design: "strip", state: "loading" },
      note: "First frame: the row is already there while the chat is read, so the brief arriving moves nothing.",
    },
    "strip-empty": {
      props: { design: "strip", state: "empty" },
      note: "A chat with nothing to brief keeps the row and says so: removing it would move the diff.",
    },
    "strip-failed": {
      props: { design: "strip", state: "failed" },
      note: "acpmux could not answer: the row says so and stays put.",
    },
    "alt-sidebar": {
      props: { design: "sidebar", state: "ready" },
      note: "Not taken: in the files sidebar it competes with the file tree for height and is gone when the sidebar is.",
    },
    "alt-inline": {
      props: { design: "inline", state: "ready" },
      note: "Not taken: a card in the diff's flow pushes every file down when it arrives and scrolls away.",
    },
  },
});
