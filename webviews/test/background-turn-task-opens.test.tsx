// l10n-allow-file: test fixture commands and output, not shipped UI.
// Leo, 2026-11-21: "background tasks not expandable. even if they're denoting completion, why
// shouldn't they get the same treatment?" A finished background turn's line ("Background task
// finished: bg-…") in the default look had no chevron and opened nothing. It now opens as a command
// row opens: the task's command, how it ended and the last lines it printed (backgroundTurnTask.ts).
import { expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { BackgroundTurnLine } from "../src/agent-session/acpmux/conversation/BackgroundTurnLine";
import {
  BACKGROUND_TURN_TAIL_LINES,
  backgroundTurnOpensTask,
  backgroundTurnTaskCard,
  backgroundTurnTaskId,
  readBackgroundTurnTask,
  taskFromBgOutput,
} from "../src/agent-session/acpmux/conversation/backgroundTurnTask";
import { BACKGROUND_TURN } from "../src/agent-session/acpmux/conversation/backgroundTurns";
import type { AcpmuxBackgroundTurn, AcpmuxRow } from "../src/agent-session/acpmux/model";

const finished: AcpmuxBackgroundTurn = {
  id: "turn-1",
  trigger: "task_notification",
  running: false,
  quiet: true,
  hasRows: true,
  cause: {
    kind: "shell",
    status: "completed",
    weight: "result",
    summary: "Background task finished: bg-53568892f4dd",
  } as AcpmuxBackgroundTurn["cause"],
};
const row = (background: AcpmuxBackgroundTurn) =>
  ({ id: `bg:${background.id}`, kind: BACKGROUND_TURN, background }) as unknown as AcpmuxRow;
const html = (background: AcpmuxBackgroundTurn) =>
  renderToStaticMarkup(
    createElement(BackgroundTurnLine, { row: row(background), expanded: false, onToggle: () => {} }),
  );
const base64 = (text: string) => btoa(String.fromCharCode(...new TextEncoder().encode(text)));

test("a finished background task's line opens, with a chevron, in the default look", () => {
  const markup = html(finished);
  expect(markup).toContain("Background task finished: bg-53568892f4dd");
  expect(markup).toContain("<button");
  expect(markup).toContain('aria-expanded="false"');
  expect(markup).toContain("cv-tool__chevron");
  expect(markup).toContain('data-opens="task"');
});

test("a running turn, or one that names no task, still opens nothing", () => {
  expect(html({ ...finished, running: true })).not.toContain("cv-tool__chevron");
  const nameless = { ...finished, cause: undefined, source: undefined };
  expect(backgroundTurnOpensTask(nameless, "Background update")).toBe(false);
  expect(html(nameless)).not.toContain("cv-tool__chevron");
});

test("the line names its task by its bg- id", () => {
  expect(backgroundTurnTaskId(finished)).toBe("bg-53568892f4dd");
  expect(backgroundTurnTaskId({ ...finished, cause: undefined }, "Background task finished: bg-0a1b2c3d")).toBe(
    "bg-0a1b2c3d",
  );
});

test("it reads the task's record and output end once, by its id", async () => {
  const asked: string[] = [];
  const reader = {
    sessionId: "s1",
    source: {
      listProcesses: () => Promise.resolve({}),
      tailProcess: () => Promise.resolve({}),
      tailTask: (id: string) => {
        asked.push(id);
        return Promise.resolve({
          id,
          command: "bun test test/agent-pane-step-rows.test.ts",
          state: "exited",
          exitCode: 1,
          startedAt: 1_000,
          endedAt: 5_200,
          data: base64("12 pass\n1 fail\n"),
          fromByte: 0,
        });
      },
    },
  };
  const first = await readBackgroundTurnTask(reader, finished)!;
  await readBackgroundTurnTask(reader, finished);
  expect(asked).toEqual(["bg-53568892f4dd"]);
  expect(first).toMatchObject({
    command: "bun test test/agent-pane-step-rows.test.ts",
    state: "exited",
    exitCode: 1,
    output: "12 pass\n1 fail\n",
    cut: false,
    tookMs: 4_200,
  });
});

test("acpmux's decoded text stands in when the reply has no bytes", () => {
  expect(taskFromBgOutput({ command: "make", text: "done\n", fromByte: 10 })).toMatchObject({
    command: "make",
    output: "done\n",
    cut: true,
  });
});

test("opened, it shows the command, the exit and only the last lines", () => {
  const output = Array.from({ length: 30 }, (_, i) => `line ${i + 1}`).join("\n") + "\n";
  const failed = backgroundTurnTaskCard({ command: "cargo build", exitCode: 2, output, state: "exited" });
  expect(failed.command).toBe("cargo build");
  expect(failed.exitCode).toBe(2);
  expect(failed.output!.split("\n")).toEqual(
    Array.from({ length: BACKGROUND_TURN_TAIL_LINES }, (_, i) => `line ${i + 31 - BACKGROUND_TURN_TAIL_LINES}`),
  );
  expect(failed.cut).toBe(true);
  // A failure says so in the card's exit line; a clean end says it in a word.
  expect(failed.ended).toBeUndefined();
  expect(backgroundTurnTaskCard({ command: "make", exitCode: 0, output: "ok", state: "exited" })).toMatchObject({
    output: "ok",
    cut: false,
    ended: "completed",
  });
});
