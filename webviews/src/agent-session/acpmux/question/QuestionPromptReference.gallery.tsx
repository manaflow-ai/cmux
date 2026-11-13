// l10n-allow-file: reference gallery prompts and mock composer, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { AgentQuestion, QuestionReply } from "./model";
import { QuestionCard } from "./QuestionCard";

const question: AgentQuestion = {
  id: "reference-html-question",
  source: {
    harness: "codex",
    session: "reference-question-session",
    permission: "reference-html-question",
    agentName: "Codex",
    answerOption: "allow_once",
    rejectOption: "reject_once",
  },
  items: [
    {
      id: "page",
      prompt: "What would you like the HTML page to show?",
      options: [
        { id: "welcome", label: "A simple welcome page" },
        { id: "dashboard", label: "A PR status dashboard" },
        { id: "portfolio", label: "A personal portfolio" },
      ],
      multiSelect: false,
      allowsOther: true,
    },
  ],
  state: { kind: "pending" },
};

function ReferenceQuestion({ freeform = false, multiple = false }: { freeform?: boolean; multiple?: boolean }) {
  const [sent, setSent] = useState<QuestionReply>();
  const [draft, setDraft] = useState("");
  const [checks, setChecks] = useState(0);
  const shown = freeform
    ? { ...question, items: [{ ...question.items[0]!, options: [] }] }
    : multiple
      ? {
          ...question,
          items: [
            question.items[0]!,
            {
              ...question.items[0]!,
              id: "appearance",
              prompt: "What appearance would you prefer?",
              options: [
                { id: "dark", label: "Dark" },
                { id: "light", label: "Light" },
                { id: "system", label: "Follow the system" },
              ],
            },
            {
              ...question.items[0]!,
              id: "content",
              prompt: "How much content should it have?",
              options: [
                { id: "brief", label: "A brief overview", detail: "Keep it concise and easy to scan." },
                {
                  id: "detailed",
                  label: "Detailed content",
                  detail: "Include examples and explanations for each section.",
                },
              ],
            },
          ],
        }
      : question;
  return (
    <div className="acpmux-shell" style={{ flexDirection: "column", justifyContent: "flex-end", gap: 8, padding: 16 }}>
      <div style={{ flex: 1 }}>
        <p>Independent work can continue while the question waits.</p>
        <button type="button" onClick={() => setChecks((count) => count + 1)}>
          Continue independent check
        </button>
        <output aria-live="polite">{checks > 0 ? `Completed ${checks} checks` : "Question pending"}</output>
      </div>
      {sent ? (
        <output data-question-reply="">{JSON.stringify(sent.answers ?? { skipped: true })}</output>
      ) : (
        <QuestionCard question={shown} onReply={setSent} />
      )}
      <textarea
        className="acpmux-composer-prompt"
        aria-label="Message composer"
        placeholder="Ask another question or continue independent work"
        value={draft}
        onChange={(event) => setDraft(event.currentTarget.value)}
        rows={3}
        style={{
          boxSizing: "border-box",
          width: "100%",
          padding: 16,
          borderRadius: 16,
          background: "var(--acpmux-question-bg)",
          color: "var(--agent-text)",
          border: "1px solid var(--agent-border)",
          font: "inherit",
        }}
      />
    </div>
  );
}

export default componentEntry({
  id: "agent-pane.question-prompt-reference",
  title: "Question prompt / Codex reference",
  area: "Agent pane",
  height: 540,
  covers: ["agent-session/acpmux/question/QuestionCard.tsx"],
  pane: true,
  styles: () => import("../styles.css"),
  load: async () => ReferenceQuestion,
  variants: {
    choices: {
      note: "Three numbered choices, a custom answer, Skip and Send. Close folds without declining; independent work and the composer stay usable.",
      props: {},
    },
    multiple: {
      note: "Three questions share a top-right pager. Navigate back and forth without submitting or losing answers.",
      props: { multiple: true },
    },
    freeform: {
      note: "A freeform-only elicitation keeps its custom answer and Send behavior.",
      props: { freeform: true },
    },
  },
});
