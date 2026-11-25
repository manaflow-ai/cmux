// A background command's finish that acpmux sends the agent as a prompt (`bg-done-<task>`, a notice
// from acpmux with the task's id and description): the turn it starts is the agent's own, not the
// person's. It draws as a background turn (backgroundTurns.ts): one line under the turn before it,
// "Background task finished: <task>", and the agent's acknowledgement draws nothing; a failure's line
// says so with its exit code, in the failure look, over the agent's reply, which says why. An
// acknowledgement is one short line with no question and no link (backgroundTurns.ts `isQuietReply`,
// acpmux's own rule for a quiet turn): a turn that reported more draws its report under the line,
// and the person's message into the turn ends it there, so the answer to them always draws (Leo,
// 2026-11-21, on a five-paragraph answer that never drew: "things dont get rendeed?";
// design/transcript-oddities.md T1). While the finish waits for the next turn it draws nothing, so no
// notice sits pinned under a running turn (Lucas, 2026-11-14: "it should keep its place in the
// turn, not move and stay sticky"; "not sure this makes much sense ... outside of the main turn").
import { translate } from "../i18n";

export type BgDone = { promptId: string; description: string; failed: boolean; exit?: number };

const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);

/// The background finish `msg` (a `user_message` or `queued` record) carries, or undefined.
export function bgDoneNotice(msg: Record<string, unknown> | undefined): BgDone | undefined {
  const promptId = text(msg?.promptId);
  if (!promptId?.startsWith("bg-done-")) return undefined;
  const meta = msg?._meta as { provenance?: Record<string, unknown> } | undefined;
  const provenance = meta?.provenance;
  const taskId = text(provenance?.bgTaskId);
  if (!provenance || !taskId || provenance.kind !== "notice") return undefined;
  const notice = provenance.notice as { title?: unknown; severity?: unknown } | undefined;
  const title = text(notice?.title) ?? "";
  const exit = /\(exit (-?\d+)\)\s*$/.exec(title)?.[1];
  // acpmux marks every end that did not go well `warn` (bg_notify.rs): a nonzero exit, and a task
  // stopped, killed or lost, which has no exit code.
  const failed = notice?.severity === "warn" || (exit !== undefined && Number(exit) !== 0);
  return {
    promptId,
    description: text(provenance.bgTaskDescription) ?? taskId,
    failed,
    ...(exit !== undefined && { exit: Number(exit) }),
  };
}

/// The `background_turn` started record a background finish stands for: a result names its task, a
/// failure says so, with its exit code when it has one.
export function bgDoneStarted(done: BgDone): Record<string, unknown> {
  const failed = done.failed;
  const exit = failed && done.exit !== undefined && done.exit !== 0 ? done.exit : undefined;
  const summary = !failed
    ? translate("bgTask.completed", { command: done.description })
    : exit === undefined
      ? translate("bgTask.failed", { command: done.description })
      : `${translate("bgTask.failed", { command: done.description })} · ${translate("tools.exit", { code: exit })}`;
  return {
    id: done.promptId,
    state: "started",
    trigger: "task_notification",
    cause: { kind: "shell", status: failed ? "failed" : "completed", weight: failed ? "failure" : "result", summary },
  };
}
