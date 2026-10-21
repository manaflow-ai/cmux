// l10n-allow-file: gallery fixtures, not shipped UI.
// The agent question card on the shared CmuxAgentQuestion fixtures (the same asks the Swift card,
// acpmux and agent-question-card.test.ts use), so the gallery advisory run captures every state on
// Linux Chromium without a Mac, a tagged build or a logged-in agent.
import pending4 from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-4-questions.json";
import pendingMulti from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-multi.json";
import pendingOther from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-other-typing.json";
import pendingSingle from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-single.json";
import pendingPreview from "../../../../../Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/pending-with-preview.json";
import { useEffect, useRef } from "react";
import { componentEntry } from "../../../gallery/format";
import type { AgentQuestion, QuestionReply } from "./model";
import { QuestionCard } from "./QuestionCard";

type Props = { question: AgentQuestion; onReply(reply: QuestionReply): void; otherText?: string };

/// The card sits where the agent pane puts it: inside .acpmux-shell (which defines the card tokens,
/// the amber input color among them) and the bottom ask stack.
function QuestionCardInPane({ otherText, ...props }: Props) {
  const pane = useRef<HTMLDivElement>(null);
  // A variant with `otherText` picks Other on the first question and types it, as a person does.
  useEffect(() => {
    const root = pane.current;
    if (!otherText || !root) return;
    // After the mount's effects, so the card's own update runs as it does for a click.
    const timer = setTimeout(() => {
      root.querySelector<HTMLElement>(".acpmux-question-other-choice")?.click();
      const field = root.querySelector<HTMLInputElement>(".acpmux-question-other input");
      if (!field) return;
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set?.call(field, otherText);
      field.dispatchEvent(new Event("input", { bubbles: true }));
    }, 0);
    return () => clearTimeout(timer);
  }, [otherText]);
  return (
    <div
      ref={pane}
      className="acpmux-shell"
      style={{ flexDirection: "column", justifyContent: "flex-end", paddingTop: 16 }}
    >
      <div className="acpmux-permission">
        <div className="acpmux-asks-stack">
          <QuestionCard {...props} />
        </div>
      </div>
    </div>
  );
}

const variant = (question: unknown, note: string, otherText?: string) => ({
  note,
  props: { question: question as AgentQuestion, onReply: () => undefined, otherText },
});

/// Leo's ask (2026-10-20): two Claude Code questions, tabbed New tab pick | References.
const pendingTwo: AgentQuestion = {
  id: "perm_toolu_two",
  source: {
    harness: "claude",
    session: "sess_claude_1",
    permission: "perm_toolu_two",
    agentName: "Claude Code",
    answerOption: "allow_once",
    rejectOption: "reject_once",
  },
  items: [
    {
      id: "q0",
      header: "New tab pick",
      prompt: "When I open a new tab, which page should it show?",
      options: [
        { id: "Start page", label: "Start page", detail: "The default start page with recent folders." },
        { id: "Last folder", label: "Last folder", detail: "Reopen the folder of the last tab." },
      ],
      multiSelect: false,
      allowsOther: true,
    },
    {
      id: "q1",
      header: "References",
      prompt: "Which references should the plan cite?",
      options: [
        { id: "Design doc", label: "Design doc", detail: "plans/cmux-next/new-tab.md" },
        { id: "None", label: "None" },
      ],
      multiSelect: false,
      allowsOther: true,
    },
  ],
  state: { kind: "pending" },
};

/// The card the daemon raises when an agent wants a sub-session in a folder nobody answered the trust
/// question for (hub/trust_wait.rs): a choice question from cmux, answered by the picked option.
const folderTrust: AgentQuestion = {
  id: "perm_trust_1",
  source: {
    harness: "acp",
    session: "sess_claude_1",
    permission: "perm_trust_1",
    agentName: "cmux",
    answerOption: "trust",
    rejectOption: "not_now",
  },
  items: [
    {
      id: "q0",
      header: "Folder trust",
      prompt: "split-importer wants to work in /Users/you/src/vendor-sdk. Do you trust this folder?",
      options: [
        {
          id: "trust",
          label: "Trust folder",
          detail: "cmux stops asking about this folder. Your permission rules still apply.",
        },
        {
          id: "not_now",
          label: "Not now",
          detail: "The sub-session does not start, and the agent is told you declined.",
        },
      ],
      multiSelect: false,
      allowsOther: false,
    },
  ],
  state: { kind: "pending" },
};

export default componentEntry({
  id: "agent-pane.question-card",
  title: "Agent question card",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 420, normal: 640, wide: 820 },
  anchors: [{ selector: ".acpmux-question" }],
  covers: ["agent-session/acpmux/question/QuestionCard.tsx#QuestionCard"],
  styles: () => import("../styles.css"),
  load: async () => QuestionCardInPane,
  variants: {
    "pending-single": variant(
      pendingSingle,
      "A Claude Code AskUserQuestion: the Needs your input pill, the question as the header, radio rows, Skip and Submit.",
    ),
    "folder-trust": variant(
      folderTrust,
      "An agent's sub-session waits in an untrusted folder: Trust folder or Not now. Trust lets the start go on by itself.",
    ),
    "pending-multi": variant(pendingMulti, "A multi-select ask: checkbox rows."),
    "pending-other-typing": variant(pendingOther, "Other turned into an inline text field."),
    "pending-with-preview": variant(pendingPreview, "Options with a preview beside the highlighted row."),
    "pending-4-questions": variant(pending4, "Four questions in one ask."),
    "pending-2-other-typed": variant(
      pendingTwo,
      "Two questions, Other picked and typed on the first: the button says Next, Enter goes to References.",
      "idk",
    ),
  },
});
