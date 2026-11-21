// l10n-allow-file: test fixture replies and model names, not shipped UI.
// Completed and stopped turns resend through the message menu. Failed recovery keeps its inline
// Retry/model control; prompt target selection is shared by both paths.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { TranscriptReadOnly } from "./readOnly";
import { TurnFooter } from "./TurnRows";
import { offersRetry, retryTargetIn, turnView, turnViewFrom } from "./turns";
import { RetryTargetContext, TurnActionsContext, type TurnActions } from "./turnActions";
import { UserBubble } from "./UserBubble";

const last: AcpmuxRow = {
  id: "summary",
  version: 1,
  at: 1_000,
  kind: "turnSummary",
  status: "completed",
  text: "Done.",
  answerId: "reply",
  retryable: true,
  retryTarget: true,
  prompt: "Cover it",
  retryRowId: "user-4",
};

const actions = (sent: unknown[][] = []): TurnActions => ({
  retry: (rowId, prompt) => sent.push(["retry", rowId, prompt]),
  retryWith: {
    models: [
      { id: "model-a", name: "Model A" },
      { id: "model-b", name: "Model B" },
    ],
    current: "model-a",
    retry: (rowId, prompt, model) => sent.push(["retryWith", rowId, prompt, model]),
  },
});

const draw = (row: AcpmuxRow, value: TurnActions = actions()) =>
  renderToStaticMarkup(
    <TurnActionsContext.Provider value={value}>
      <TurnFooter row={row} />
    </TurnActionsContext.Provider>,
  );

test("a completed footer keeps Copy and omits inline Retry and its model switch", () => {
  const markup = draw(last);
  expect(markup).toContain('aria-label="Copy"');
  expect(markup).not.toContain('aria-label="Retry"');
  expect(markup).not.toContain("cv-turn-retry");
});

test("an earlier turn's footer offers no Retry", () => {
  const markup = draw({ ...last, retryable: undefined, prompt: undefined, retryRowId: undefined });
  expect(markup).not.toContain('aria-label="Retry"');
  expect(markup).not.toContain("cv-turn-retry");
});

test("a chat that cannot send draws no Retry on its last footer", () => {
  expect(draw(last, {})).not.toContain('aria-label="Retry"');
});

test("failed recovery with one model draws Retry without the model switch", () => {
  const markup = draw(
    { ...last, status: "failed", error: "boom" },
    { ...actions(), retryWith: { models: [{ id: "a", name: "A" }], retry: () => {} } },
  );
  expect(markup).toContain('aria-label="Retry"');
  expect(markup).not.toContain("cv-turn-retry-menu");
});

test("a failed last turn keeps its Retry and model switch in the same place", () => {
  const markup = draw({ ...last, status: "failed", error: "boom" });
  expect(markup).toMatch(/<span class="cv-turn-retry"><button[^>]*aria-label="Retry"/);
  expect(markup).toContain("cv-turn-retry-menu");
});

// A turn a notification started has no prompt to send again, so Retry stays with the person's last
// prompt, on its own turn's footer, as the prompt's Retry stayed under it before (cmux#34779). Once
// the person sends another prompt, Retry moves to that turn, also when the view builds on the last.
test("Retry stays on the person's last prompt's footer when a notification's turn follows", () => {
  const prompt = (id: string, at: number, text: string): AcpmuxRow => ({ id, version: 1, at, kind: "user", text });
  const reply = (id: string, at: number, text: string): AcpmuxRow => ({ id, version: 1, at, kind: "assistant", text });
  const summary = (id: string, at: number): AcpmuxRow => ({
    id,
    version: 1,
    at,
    kind: "turnSummary",
    status: "completed",
  });
  const notice: AcpmuxRow = {
    id: "n",
    version: 1,
    at: 40,
    kind: "user",
    text: "<task-notification>done</task-notification>",
    incoming: { kind: "notice", text: "Build finished" },
  };
  const rows = [
    prompt("p1", 10, "Fix the grid"),
    reply("a1", 20, "Fixed."),
    summary("s1", 30),
    notice,
    reply("a2", 50, "The build is done."),
    summary("s2", 60),
  ];
  const view = turnViewFrom(rows, new Set(), { now: 100 });
  const footers = view.rows.filter((row) => row.kind === "turnSummary");
  expect(footers.map(offersRetry)).toEqual([true, false]);
  expect(footers[0]!.prompt).toBe("Fix the grid");
  const next = [...rows, prompt("p2", 70, "Now the header"), reply("a3", 80, "Done."), summary("s3", 90)];
  const built = turnViewFrom(next, new Set(), { now: 100 }, view);
  expect(built.rows.filter((row) => row.kind === "turnSummary").map(offersRetry)).toEqual([false, false, true]);
});

// A suggested task's result acpmux sent into the chat (`received`) is not the person's prompt
// (direct.ts), so its turn's footer never resends it: Retry stays with the person's last prompt.
test("a task result's turn offers no Retry; the person's last prompt keeps it", () => {
  const rows: AcpmuxRow[] = [
    { id: "p1", version: 1, at: 10, kind: "user", text: "Fix the grid" },
    { id: "a1", version: 1, at: 20, kind: "assistant", text: "Fixed." },
    { id: "s1", version: 1, at: 30, kind: "turnSummary", status: "completed" },
    {
      id: "r",
      version: 1,
      at: 40,
      kind: "user",
      text: "Task result: the header is done.",
      received: { offerId: "o1", childSessionId: "child-1", title: "Header" },
    },
    { id: "a2", version: 1, at: 50, kind: "assistant", text: "Merged the header." },
    { id: "s2", version: 1, at: 60, kind: "turnSummary", status: "completed" },
  ];
  const footers = turnViewFrom(rows, new Set(), { now: 100 }).rows.filter((row) => row.kind === "turnSummary");
  expect(footers.map(offersRetry)).toEqual([true, false]);
  expect(footers[0]!.prompt).toBe("Fix the grid");
});

// Target selection remains personal-prompt only when inline resend is absent.
const P = (id: string, at: number, text: string): AcpmuxRow => ({ id, version: 1, at, kind: "user", text });
const A = (id: string, at: number, text: string): AcpmuxRow => ({ id, version: 1, at, kind: "assistant", text });
const S = (id: string, at: number): AcpmuxRow => ({ id, version: 1, at, kind: "turnSummary", status: "completed" });
const tool = (id: string, at: number): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind: "activity",
  items: [{ kind: "tool", text: "", tool: { id, title: "ls", kind: "execute", status: "completed" } }],
});
const notice = (id: string, at: number): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind: "user",
  text: "<task-notification>done</task-notification>",
  incoming: { kind: "notice", text: "Build finished" },
});
const received = (id: string, at: number): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind: "user",
  text: "Task result: the header is done.",
  received: { offerId: "o1", childSessionId: "child-1", title: "Header" },
});

const message = (id: string, at: number): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind: "user",
  text: '<cross-session-message from-name="leoli-fb">Please review #123.</cross-session-message>',
  incoming: { kind: "message", message: { name: "leoli-fb", text: "Please review #123.", raw: "Please review #123." } },
});

/// Where each drawn row shows a Retry button, as the transcript renders it: "footer:<id>" or
/// "prompt:<id>".
function retries(source: AcpmuxRow[], value: TurnActions = actions(), readOnly = false): string[] {
  const rows = turnView(source, new Set(), { now: 1_000 });
  const target = retryTargetIn(rows);
  const shown: string[] = [];
  for (const row of rows) {
    const node =
      row.kind === "turnSummary" ? (
        <TurnFooter row={row} />
      ) : row.kind === "user" && !row.incoming && !row.received ? (
        <UserBubble row={row} text={row.text ?? ""} />
      ) : undefined;
    if (!node) continue;
    const markup = renderToStaticMarkup(
      <TranscriptReadOnly.Provider value={readOnly}>
        <TurnActionsContext.Provider value={value}>
          <RetryTargetContext.Provider value={target}>{node}</RetryTargetContext.Provider>
        </TurnActionsContext.Provider>
      </TranscriptReadOnly.Provider>,
    );
    if (markup.includes('aria-label="Retry"')) shown.push(`${row.kind === "user" ? "prompt" : "footer"}:${row.id}`);
  }
  return shown;
}

const reply = [P("p1", 10, "Fix the grid"), A("a1", 20, "Fixed."), S("s1", 30)];
test.each([
  ["a normal reply retains its personal prompt target", reply, "p1"],
  [
    "a tool-only last turn retains its personal prompt target",
    [P("p1", 10, "List it"), tool("t1", 20), S("s1", 30)],
    "p1",
  ],
  [
    "a notification leaves the personal prompt target unchanged",
    [...reply, notice("n", 40), A("a2", 50, "Built."), S("s2", 60)],
    "p1",
  ],
  [
    "a self-started summary leaves the personal prompt target unchanged",
    [...reply, A("a2", 40, "Also checked CI."), S("s2", 50)],
    "p1",
  ],
  [
    "a history turn without a summary still identifies its personal prompt",
    [P("p1", 10, "First"), A("a1", 20, "Done.")],
    "p1",
  ],
  [
    "a task result cannot replace the personal prompt target",
    [...reply, received("r", 40), A("a2", 50, "Merged."), S("s2", 60)],
    "p1",
  ],
  [
    "another agent's message cannot replace the personal prompt target",
    [...reply, message("m", 40), A("a2", 50, "Reviewing."), S("s2", 60)],
    "p1",
  ],
  ["only another agent's message: none", [message("m", 10), A("a1", 20, "Reviewing."), S("s1", 30)], undefined],
  ["only a task result: none", [received("r", 10), A("a1", 20, "Merged."), S("s1", 30)], undefined],
  [
    "a later personal prompt replaces the target",
    [...reply, P("p2", 40, "Now the header"), A("a2", 50, "Done."), S("s2", 60)],
    "p2",
  ],
] as const)("%s", (_name, source, expected) => {
  const rows = turnView([...source], new Set(), { now: 1_000 });
  expect(retryTargetIn(rows).promptId).toBe(expected);
  expect(retries([...source])).toEqual([]);
});

test("a reader who may not act, or a chat that cannot send now, sees no Retry anywhere", () => {
  const toolOnly = [P("p1", 10, "List it"), tool("t1", 20), S("s1", 30)];
  for (const source of [reply, toolOnly]) {
    expect(retries(source, actions(), true)).toEqual([]);
    expect(retries(source, {})).toEqual([]);
  }
});

test("a waiting steer remains the latest target without an inline Retry", () => {
  const steer: AcpmuxRow = { ...P("p2", 30, "Also the header"), steer: "waiting" };
  const rows = turnView([P("p1", 10, "Fix the grid"), A("a1", 20, "Working."), steer], new Set(), { now: 1_000 });
  const target = retryTargetIn(rows);
  expect(target.promptId).toBe("p2");
  const row = rows.find((item) => item.id === "p2")!;
  const markup = renderToStaticMarkup(
    <TurnActionsContext.Provider value={actions()}>
      <RetryTargetContext.Provider value={target}>
        <UserBubble
          row={row}
          text={row.text ?? ""}
          pending={(rowActions, queued) => (
            <div className="steer-queue">
              {rowActions}
              {queued.retry}
            </div>
          )}
        />
      </RetryTargetContext.Provider>
    </TurnActionsContext.Provider>,
  );
  const queue = markup.slice(markup.indexOf('class="steer-queue"'));
  expect(queue).not.toContain('aria-label="Retry"');
});
