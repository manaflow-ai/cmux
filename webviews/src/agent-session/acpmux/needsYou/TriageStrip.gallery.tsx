// l10n-allow-file: gallery fixtures (sample commands and plan text), not shipped UI.
// The triage strip (wow idea 22): from anywhere, Ctrl-Cmd-; opens the chat that has waited longest
// on the person, and Ctrl-Cmd-Y answers the chat on screen and opens the next one. The strip on top
// of the waiting ask says what the keys do here before either is pressed, above the card that shows
// the exact command, plan or question. Three looks:
// - strip (shipped): how long this ask has waited and how many more wait, then both keys.
// - keys: only the keys, at the strip's start.
// - chip: the count and the answer key as one small rounded rect at the card's end.
// And the shipped strip on each kind of ask: a plan, a question's first choice, a typed question
// (the key only skips it), and the last waiting chat (no Next key).
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { AcpmuxPermission } from "../model";
import { PermissionCard } from "../PermissionCard";
import { SHORTCUT_ACTIONS, ShortcutsContext } from "../shortcuts";
import type { NeedsYouItem } from "./model";
import type { TriageMove } from "./triage";
import { TriageStrip, type TriageStripLook } from "./TriageStrip";

type Ask = "command" | "plan" | "choice" | "typed";
type Props = { look: TriageStripLook; ask: Ask; others: number };

const NOW = Date.UTC(2026, 10, 8, 12, 0);

const labels = {
  [SHORTCUT_ACTIONS.permissionAllowOnce]: "⌥⌘1",
  [SHORTCUT_ACTIONS.permissionAllowChat]: "⌥⌘2",
  [SHORTCUT_ACTIONS.permissionDeny]: "⌥⌘3",
  [SHORTCUT_ACTIONS.triageAnswer]: "⌃⌘Y",
  [SHORTCUT_ACTIONS.triageNext]: "⌃⌘;",
};

const options: AcpmuxPermission["options"] = [
  { id: "allow_always", name: "Always Allow", kind: "allow_always", allow: true },
  { id: "allow", name: "Allow", kind: "allow_once", allow: true },
  { id: "reject", name: "Reject", kind: "reject_once", allow: false },
];

const command: AcpmuxPermission = {
  permissionId: "gallery-triage-command",
  kind: "execute",
  title: "`pnpm test`",
  command: "pnpm test --filter @app/billing -- --run invoices.test.ts",
  description: "Run the invoice tests",
  pending: true,
  options,
};

const plan: AcpmuxPermission = {
  permissionId: "gallery-triage-plan",
  kind: "other",
  title: "Approve plan",
  plan: "1. Split `upload.ts` into the client and the retry queue.\n2. Add a test for a dropped chunk.\n3. Run the upload suite.",
  pending: true,
  options: [
    { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
    { id: "reject_once", name: "Reject", kind: "reject_once", allow: false },
  ],
};

const question = {
  id: "acpmux:gallery-triage-question",
  kind: "decision",
  sessionId: "s-question",
  ask: "Which database should the migration target?",
  who: { name: "migrations", harness: "claude", chief: false },
  answers: [
    { id: "staging", label: "Staging", tone: "choice" },
    { id: "local", label: "Local", tone: "choice" },
  ],
} satisfies NeedsYouItem;

const moves: Record<Ask, TriageMove> = {
  command: { kind: "allow", plan: false },
  plan: { kind: "allow", plan: true },
  choice: { kind: "choice", item: question, answer: question.answers[0]! },
  typed: { kind: "skip" },
};

const QuestionStandIn = ({ text }: { text: string }) => (
  <div
    className="acpmux-permission-card"
    style={{
      padding: "var(--ds-space-3) var(--ds-space-4)",
      borderRadius: "var(--ds-radius-popup)",
      border: "0.5px solid var(--agent-border)",
      color: "var(--agent-text)",
    }}
  >
    {text}
  </div>
);

function GalleryTriageStrip({ look, ask, others }: Props) {
  const card =
    ask === "command" || ask === "plan" ? (
      <PermissionCard permission={ask === "plan" ? plan : command} harness="claude" onAnswer={() => undefined} />
    ) : (
      <QuestionStandIn
        text={ask === "choice" ? question.ask : "Describe the rollback you want, step by step (a typed answer)."}
      />
    );
  return (
    <div className="acpmux-shell" style={{ paddingTop: 12 }}>
      <div className="acpmux-main">
        <ShortcutsContext value={labels}>
          <div className="acpmux-permission acpmux-asks-stack">
            <TriageStrip move={moves[ask]} others={others} at={NOW - 6 * 60_000} now={NOW} look={look} />
            {card}
          </div>
        </ShortcutsContext>
      </div>
    </div>
  );
}

/// The strip is one line: a long count or label never wraps it.
const oneLine: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-triage"));
  const strip = ctx.document.querySelector<HTMLElement>(".acpmux-triage")!;
  if (strip.getBoundingClientRect().height > 30) throw new Error("The triage strip wrapped onto a second line");
};

const variant = (note: string, props: Props) => ({ note, props, play: oneLine });

export default componentEntry<Props>({
  id: "agent-pane.triage-strip",
  title: "Agent pane: the triage keys over a waiting ask",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/needsYou/TriageStrip.tsx#TriageStrip"],
  load: async () => GalleryTriageStrip,
  styles: () =>
    Promise.all([
      import("../../../ui/glass/glass.css"),
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("../keys.css"),
      import("./triage.css"),
    ]),
  widths: { narrow: 360, normal: 540, wide: 760 },
  height: 300,
  variants: {
    strip: variant(
      "Shipped: how long this ask has waited and how many more wait, then ⌃⌘Y Allow once & next and ⌃⌘; Next, over the card with the exact command.",
      { look: "strip", ask: "command", others: 3 },
    ),
    keys: variant("Alternative: only the keys. Quieter, but the person cannot tell how much is left.", {
      look: "keys",
      ask: "command",
      others: 3,
    }),
    chip: variant(
      "Alternative: the count and the answer key as one small rounded rect at the card's end; no Next key.",
      {
        look: "chip",
        ask: "command",
        others: 3,
      },
    ),
    plan: variant("A plan approval: the key approves the plan, as the card's Approve plan does.", {
      look: "strip",
      ask: "plan",
      others: 2,
    }),
    choice: variant("A question with one-click choices: the key takes the first choice, named.", {
      look: "strip",
      ask: "choice",
      others: 1,
    }),
    typed: variant("A question that needs a typed answer: the key only moves on; the chat stays waiting.", {
      look: "strip",
      ask: "typed",
      others: 4,
    }),
    last: variant("The last waiting chat: no Next key, and the answer key stays here after answering.", {
      look: "strip",
      ask: "command",
      others: 0,
    }),
  },
});
