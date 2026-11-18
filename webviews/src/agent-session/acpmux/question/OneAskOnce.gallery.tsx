// l10n-allow-file: gallery fixtures, not shipped UI.
// One ask renders once (Leo, 2026-11-15, with one [taste] ask drawn twice over the composer, pinned
// under "Needs your input" and again in the composer hat: "there should not be 2 of these"). The
// bottom stack as the pane builds it: the pinned asks (conversation/PendingAsks.tsx) over the hat
// (HatQuestions.tsx), whose list goes through the pane's own selector (hatSeen.ts
// `hatQuestionsShown`), so a pinned ask leaves the hat and the hat keeps every other question.
import { NextStepCard } from "../conversation/NextStepCard";
import { nextStepAsk } from "../conversation/nextStepAsk";
import { PendingAsks } from "../conversation/PendingAsks";
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxRow } from "../model";
import type { HatQuestion } from "./hatModel";
import { HatQuestions, type HatQuestionActions } from "./HatQuestions";
import { hatQuestionsShown, stackCardKeys } from "./hatSeen";
import { askKey } from "../conversation/waitingAskStore";

type Props = {
  /// Another turn came after the ask, so it is pinned (`waitingAsks`); before that the hat holds it.
  pinned: boolean;
  /// A started chat's question waits too.
  child?: boolean;
  /// The pane before the fix, for comparison: the hat ignores the pinned cards.
  twice?: boolean;
};

const ASKED =
  "Ready for review.\n\n[taste] Is 32 px right for the live line in #43627?\nIf yes, it merges at 32 and the value moves to one place.";
const ask = nextStepAsk(ASKED)!;
const row = { id: "nextStep-1", version: 1, at: 1_000, kind: "nextStep", nextStep: { ask } } as AcpmuxRow;

const tagged: HatQuestion = {
  id: `next:${row.id}`,
  source: "nextStep",
  sessionId: "chat",
  answerKey: askKey(row),
  tag: "taste",
  prompt: ask.question,
  ...(ask.detail ? { detail: ask.detail } : {}),
  answers: ask.options.map((option) => ({
    id: option.label,
    label: option.label,
    ...(option.key ? { key: option.key } : {}),
  })),
  typed: true,
  ask,
};
const started: HatQuestion = {
  id: "acpmux:perm-cleanup",
  source: "child",
  sessionId: "coord-deputy",
  who: "coord-deputy",
  about: "Cleanup",
  prompt: "Two stale worktrees hold 40 GB on the build Mac. Remove both now, or leave them for their owner?",
  answers: [
    { id: "Remove both (Recommended)", label: "Remove both", recommended: true },
    { id: "Leave them", label: "Leave them" },
  ],
  typed: true,
};

const noop = () => Promise.resolve();
const actions: HatQuestionActions = {
  answer: noop,
  reply: noop,
  type: () => undefined,
  showCard: () => undefined,
  open: () => undefined,
  dismiss: () => undefined,
};

function OneAskOnce({ pinned, child = false, twice = false }: Props) {
  const asks = pinned ? [row] : [];
  const read = child ? [tagged, started] : [tagged];
  const onStack = twice ? new Set<string>() : stackCardKeys(asks, undefined);
  const hat = hatQuestionsShown(read, new Set(), onStack);
  return (
    <div
      className="acpmux-shell"
      data-one-ask={twice ? "twice" : "once"}
      style={{ flexDirection: "column", justifyContent: "flex-end", gap: 12, padding: 16 }}
    >
      <p style={{ margin: 0, color: "var(--agent-text)" }}>{ask.rest}</p>
      <NextStepCard ask={ask} onAnswer={noop} />
      {pinned && (
        <p style={{ margin: 0, color: "var(--agent-muted)" }}>
          <strong style={{ color: "var(--agent-soft)" }}>helper</strong> Pushed abc123; checks are running.
        </p>
      )}
      {asks.length > 0 && (
        <div className="acpmux-permission acpmux-asks-stack" style={{ padding: 0 }}>
          <PendingAsks asks={asks} onAnswer={noop} registerKey={() => () => undefined} onDismiss={() => undefined} />
        </div>
      )}
      <HatQuestions questions={hat} actions={actions} />
      <div
        style={{
          minHeight: 44,
          borderRadius: "var(--ds-radius-popup)",
          border: "0.5px solid var(--agent-border)",
          background: "var(--agent-input-bg)",
          color: "var(--agent-muted)",
          padding: "var(--ds-space-3)",
          boxSizing: "border-box",
        }}
      >
        Message
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.one-ask-once",
  title: "Agent pane: one ask, one card over the composer",
  area: "Agent pane",
  pane: true,
  height: 560,
  widths: { narrow: 420, normal: 640, wide: 900 },
  covers: ["agent-session/acpmux/question/hatSeen.ts#hatQuestionsShown"],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../bottomStack.css"),
      import("../conversation/PendingAsks.css"),
      import("./hatQuestions.css"),
    ]),
  load: async () => OneAskOnce,
  variants: {
    pinned: {
      note: "Shipped: another turn came after the ask, so it is pinned under Needs your input with ⌘↩ and Dismiss; the hat stays away.",
      props: { pinned: true },
    },
    "hat-alone": {
      note: "Before another turn: nothing is pinned, and the ask waits in the hat alone.",
      props: { pinned: false },
    },
    "pinned-and-started-chat": {
      note: "The pinned ask and a started chat's question: the hat holds only the started chat's.",
      props: { pinned: true, child: true },
    },
    twice: {
      note: 'Before the fix, for comparison: the same ask pinned and again in the hat (Leo: "there should not be 2 of these").',
      props: { pinned: true, twice: true },
    },
  },
});
