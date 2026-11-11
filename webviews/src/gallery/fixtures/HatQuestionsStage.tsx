// l10n-allow-file: gallery fixtures (questions, stage composer), not shipped UI.
// The agent's questions in the composer hat (agent-session/acpmux/question/HatQuestions.tsx) over a
// stand-in composer: three questions wait (the chat's own, a tagged [physical] ask, a started chat's),
// the pager steps through them, a click answers one, and a reply typed in the composer withdraws the
// chat's own question, which then leaves the hat (Leo, 2026-11-07: "the composer hat can become a
// dual thing where you can go through it and, like, click left and right through things and be able
// to answer things as they come").
import { useState, type CSSProperties } from "react";
import { HatQuestions, type HatQuestionActions } from "../../agent-session/acpmux/question/HatQuestions";
import type { HatQuestion } from "../../agent-session/acpmux/question/hatModel";

export const STAGE_QUESTIONS: readonly HatQuestion[] = [
  {
    id: "perm-own",
    source: "own",
    tag: "taste",
    prompt: "Which auth method should the API use?",
    answers: [
      { id: "oauth", label: "OAuth 2.0" },
      { id: "keys", label: "API keys" },
      { id: "passkeys", label: "Passkeys" },
    ],
    typed: true,
  },
  {
    id: "next:row-1",
    source: "nextStep",
    tag: "physical",
    prompt: "Can you create that key and run the command?",
    detail: "It needs your hardware key; I'll wait for the output.",
    answers: [
      { id: "Yes", label: "Yes", key: "recap.yes" },
      { id: "Not now", label: "Not now", key: "recap.notNow" },
    ],
    typed: true,
  },
  {
    id: "acpmux:perm-child",
    source: "child",
    sessionId: "child",
    who: "From claude-sr2-coord: coord-deputy left real product asks open",
    prompt:
      "[irreversible] The build Mac's uplink is still saturated (round trips about 5 s, down from 11.5 s), which keeps GitHub calls from that Mac slow. Move its builds?",
    answers: [],
    typed: false,
  },
];

export function HatQuestionsStage({
  count = 3,
  look,
  dismissLook,
  first,
}: {
  count?: number;
  look?: "band" | "line" | "chip";
  dismissLook?: "hover" | "always" | "corner";
  /// Which question leads: the stills of the started chat's question start on it.
  first?: "child";
}) {
  const start = () => {
    const some = STAGE_QUESTIONS.slice(0, count);
    return first === "child"
      ? [...some.filter((q) => q.source === "child"), ...some.filter((q) => q.source !== "child")]
      : some;
  };
  const [questions, setQuestions] = useState<readonly HatQuestion[]>(start);
  const [draft, setDraft] = useState("");
  const [log, setLog] = useState<string[]>([]);
  const drop = (id: string, why: string) => {
    setQuestions((now) => now.filter((question) => question.id !== id));
    setLog((now) => [...now, why]);
  };
  const actions: HatQuestionActions = {
    // The source says it is over a moment after the click, as acpmux's decision record does.
    answer: (question, answer) =>
      new Promise((resolve) =>
        setTimeout(() => {
          drop(question.id, `answered: ${answer.label}`);
          resolve(undefined);
        }, 120),
      ),
    type: () => document.querySelector<HTMLInputElement>("[data-stage-composer]")?.focus(),
    showCard: () => undefined,
    open: (question) => setLog((now) => [...now, `opened ${question.who ?? ""}`]),
    dismiss: (question) => drop(question.id, `dismissed: ${question.prompt.slice(0, 24)}`),
  };
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100vh", background: "var(--agent-page-bg)" }}>
      <div
        style={{
          display: "flex",
          gap: "var(--ds-space-2)",
          padding: "var(--ds-space-2)",
          borderBottom: "1px solid var(--agent-border)",
        }}
      >
        <button type="button" data-stage="reset" onClick={() => setQuestions(start())}>
          Three wait
        </button>
        <button type="button" data-stage="clear" onClick={() => setQuestions([])}>
          None wait
        </button>
        <output data-stage-log="">{log.join(" · ")}</output>
      </div>
      <main
        className="acpmux-main"
        data-dock="float"
        style={{ position: "relative", flex: 1, minHeight: 0, display: "flex", flexDirection: "column" }}
      >
        <div style={{ flex: 1 }} />
        <div className="acpmux-dock" style={{ "--cv-inset": "16px" } as CSSProperties}>
          {questions.length > 0 && (
            <HatQuestions questions={questions} actions={actions} look={look} dismissLook={dismissLook} />
          )}
          <div className="acpmux-composer">
            <form
              className="acpmux-composer-box"
              style={{
                margin: "0 16px 16px",
                height: 72,
                borderRadius: 12,
                padding: 12,
                boxSizing: "border-box",
                background: "var(--acpmux-composer-tray)",
                boxShadow: "inset 0 0 0 1px var(--agent-border)",
              }}
              onSubmit={(event) => {
                event.preventDefault();
                if (!draft.trim()) return;
                // A typed reply withdraws the chat's own waiting question (App.tsx withdrawForTypedReply).
                const own = questions.find((question) => question.source === "own");
                if (own) drop(own.id, `answered in chat: ${draft}`);
                setDraft("");
              }}
            >
              <input
                data-stage-composer=""
                aria-label="Message"
                value={draft}
                placeholder="Message"
                onChange={(event) => setDraft(event.target.value)}
                style={{ width: "100%", border: 0, background: "none", color: "var(--agent-text)", font: "inherit" }}
              />
            </form>
          </div>
        </div>
      </main>
    </div>
  );
}
