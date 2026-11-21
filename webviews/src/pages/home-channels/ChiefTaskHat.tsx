// The composer hat's background tasks (chiefTasks.ts): one quiet row per task the Chief runs with no
// workspace, over the composer. A running row shows its title and elapsed time; a finished one its
// one-line result until it expires. Nothing shows when no task is live or recent, so the composer
// never moves for an empty hat. Looks: `rows` (shipped), `chips` and `summary`, in the gallery.
import { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { RunMark, useNow } from "./RunCard";
import { chiefTasks, nextExpiry, type ChiefTask } from "./chiefTasks";
import { formatDuration } from "../../agent-session/acpmux/conversation/turns";
import type { RunBook } from "./runs";

export type ChiefTaskHatLook = "rows" | "chips" | "summary";

const STATUS = { running: "running", stalled: "stale", done: "done", stopped: "cancelled" } as const;

export function ChiefTaskHat({
  book,
  conversation,
  strings,
  look = "rows",
  now: fixedNow,
}: {
  book: RunBook;
  conversation: string;
  strings: Strings;
  look?: ChiefTaskHatLook;
  /** A fixed clock (the gallery). */
  now?: number;
}) {
  const subscribe = useCallback((listener: () => void) => book.subscribe(listener), [book]);
  const version = useSyncExternalStore(subscribe, book.getVersion);
  // One re-read at the next boundary: a finished task's expiry, a running one's stall, a stalled
  // one's removal. None while the hat is empty.
  const [expired, setExpired] = useState(0);
  const tickNow = Date.now();
  const tasks = useMemo(
    () => chiefTasks(book.entriesOf(conversation), fixedNow ?? Date.now()),
    // `version` and `expired` are the store's and the expiry's change marks.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [book, conversation, version, expired, fixedNow],
  );
  const running = tasks.some((t) => t.state === "running");
  const now = useNow(running && fixedNow === undefined);
  useEffect(() => {
    if (fixedNow !== undefined) return;
    const at = nextExpiry(tasks);
    if (at === undefined) return;
    const timer = setTimeout(() => setExpired((n) => n + 1), Math.max(0, at - tickNow));
    return () => clearTimeout(timer);
  }, [tasks, fixedNow, tickNow]);
  if (!tasks.length) return null;
  const at = fixedNow ?? now;
  const label = strings.t("tasks.hat.label");
  if (look === "summary") {
    const live = tasks.filter((t) => t.state === "running" || t.state === "stalled").length;
    return (
      <output className="lg-task-hat summary" aria-label={label}>
        <RunMark status={live ? "running" : "done"} />
        <span className="lg-task-hat__title">{label}</span>
        <span className="lg-task-hat__meta">
          {live ? `${live} ${strings.t("run.status.running")}` : `${tasks.length} ${strings.t("run.status.done")}`}
        </span>
      </output>
    );
  }
  return (
    <ul className={`lg-task-hat ${look}`} aria-label={label}>
      {tasks.map((task) => (
        <TaskRow key={task.key} task={task} now={at} strings={strings} chip={look === "chips"} />
      ))}
    </ul>
  );
}

function TaskRow({ task, now, strings, chip }: { task: ChiefTask; now: number; strings: Strings; chip: boolean }) {
  const status = STATUS[task.state];
  const live = task.state === "running" || task.state === "stalled";
  const meta = live ? formatDuration(Math.max(0, now - task.startedAt)) : strings.t(`run.status.${status}`);
  return (
    <li className="lg-task-hat__row" data-state={task.state} title={task.result ?? task.title}>
      <RunMark status={status} />
      <span className="lg-task-hat__title" dir="auto">
        {task.title}
      </span>
      {!chip && task.result && (
        <span className="lg-task-hat__result" dir="auto">
          {task.result}
        </span>
      )}
      <span className="lg-task-hat__meta">{task.state === "stalled" ? strings.t("run.status.stale") : meta}</span>
    </li>
  );
}
