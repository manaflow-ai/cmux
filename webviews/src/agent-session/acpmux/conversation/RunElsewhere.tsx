// "Run on a bigger machine" (runElsewhereModel.ts): a chip at the edge of a shell row that has run
// for 20 s, and under the row either the panel that shows exactly what would go (the commit, each
// changed file, the secret-looking files left out, the untracked files that stay) and where, or
// the run itself, its output streaming from the other machine. The chip sits in the row's trailing
// column, where a running row has no mark, so its arrival moves nothing; the panel and the run open
// below the row as a disclosure does.
import type { KeyboardEvent, MouseEvent } from "react";
import { useContext, useEffect, useRef, useState } from "react";
import { DialogButton } from "../../../ui/DialogButton";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import {
  RunElsewhereContext,
  appendOutput,
  chipDueAt,
  decodeChunk,
  firstMachine,
  nextReadDelay,
  useRun,
  type RunElsewhere as Runs,
  type RunPlan,
  type RunState,
} from "./runElsewhereModel";

const CHIP_ICON = rowIconSize(12);
/** The untracked paths the panel names; the rest are counted. */
const UNTRACKED_SHOWN = 6;
/** Failed output reads in a row before the run reads as ended. */
const READ_FAILURES = 5;
let lastMachine: string | undefined;

/** Whether `due` has passed, re-rendering once when it does (one timer, gone on unmount). */
function usePast(due: number | undefined, now: () => number = Date.now): boolean {
  const [past, setPast] = useState(() => due !== undefined && now() >= due);
  useEffect(() => {
    if (due === undefined) {
      setPast(false);
      return;
    }
    const left = due - now();
    if (left <= 0) {
      setPast(true);
      return;
    }
    setPast(false);
    const timer = setTimeout(() => setPast(true), left);
    return () => clearTimeout(timer);
  }, [due, now]);
  return past;
}

/** Opens the panel: reads what would go, then shows it. */
function openPanel(runs: Runs, toolCallId: string, command: string) {
  runs.store.set(toolCallId, { phase: "loading" });
  runs.client.plan(command).then(
    (plan) => {
      if (runs.store.get(toolCallId)?.phase !== "loading") return;
      const machine = firstMachine(plan.machines, lastMachine);
      runs.store.set(toolCallId, { phase: "choosing", plan, machine, send: [] });
    },
    (error: unknown) => {
      if (runs.store.get(toolCallId)?.phase !== "loading") return;
      // A host that does not pass the plan on (not on its relay allowlist) is said as such, never
      // its transport error ("Refused by the cmux host" read as a reason the command stays). A
      // dropped connection is not that, so only the allowlist's own refusal counts.
      const plan: RunPlan =
        (error as { code?: unknown })?.code === "transport.method_refused"
          ? { eligible: false, unavailable: true, machines: [] }
          : { eligible: false, why: String((error as Error)?.message ?? error), machines: [] };
      runs.store.set(toolCallId, { phase: "choosing", plan, send: [] });
    },
  );
}

/** The chip, on a running shell row from 20 s on, while no run of it is open. */
export function RunElsewhereChip({
  toolCallId,
  kind,
  command,
  startedAt,
  running,
  now,
}: {
  toolCallId: string;
  kind?: string;
  command?: string;
  startedAt?: number;
  running: boolean;
  now?: () => number;
}) {
  const t = useT();
  const runs = useContext(RunElsewhereContext);
  const run = useRun(runs, toolCallId);
  const due = runs ? chipDueAt({ kind, command, startedAt, running }) : undefined;
  const past = usePast(due, now);
  if (!runs || !past || !command || run) return null;
  const open = (event: MouseEvent | KeyboardEvent) => {
    // The chip sits in the row's toggle: it never opens or closes the row (as PreviewChip.tsx).
    event.preventDefault();
    event.stopPropagation();
    openPanel(runs, toolCallId, command);
  };
  return (
    <span
      className="cv-run-elsewhere-chip"
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a <button> may not sit in the row's <button>
      role="button"
      tabIndex={0}
      title={t("runElsewhere.chipHint")}
      data-find-skip
      onClick={open}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") open(event);
      }}
    >
      <Icon name="machine.remote" size={CHIP_ICON} row fit />
      <span className="cv-run-elsewhere-chip__label">{t("runElsewhere.chip")}</span>
    </span>
  );
}

/** Under the row: the panel while choosing, else the run. Nothing while no run is open. */
export function RunElsewhereBelow({ toolCallId, command }: { toolCallId: string; command?: string }) {
  const runs = useContext(RunElsewhereContext);
  const run = useRun(runs, toolCallId);
  if (!runs || !run || !command) return null;
  if (run.phase === "loading") return <RunElsewhereLoading />;
  if (run.phase === "choosing")
    return <RunElsewherePanel runs={runs} toolCallId={toolCallId} command={command} run={run} />;
  return <RunElsewhereStream runs={runs} toolCallId={toolCallId} run={run} />;
}

/** The panel's first frame while acpmux reads the tree: its title in place, so the panel grows from it. */
function RunElsewhereLoading() {
  const t = useT();
  return (
    <div className="cv-run-elsewhere cv-run-elsewhere--loading" aria-busy="true">
      <div className="cv-run-elsewhere__head">
        <span className="cv-run-elsewhere__title">{t("runElsewhere.title")}</span>
        <span className="cv-run-elsewhere__base">{t("runElsewhere.checking")}</span>
      </div>
    </div>
  );
}

function RunElsewherePanel({
  runs,
  toolCallId,
  command,
  run,
}: {
  runs: Runs;
  toolCallId: string;
  command: string;
  run: Extract<RunState, { phase: "choosing" }>;
}) {
  const t = useT();
  const { plan, machine, send } = run;
  const tree = plan.tree;
  const update = (patch: Partial<typeof run>) => runs.store.set(toolCallId, { ...run, ...patch });
  const close = () => runs.store.set(toolCallId, undefined);
  const start = () => {
    if (!machine || !tree) return;
    update({ starting: true, error: undefined });
    lastMachine = machine;
    runs.client.start(command, machine, tree.digest, send).then(
      (task) => runs.store.set(toolCallId, { phase: "running", machine, taskId: task.id, output: "" }),
      (error: unknown) =>
        runs.store.set(toolCallId, { ...run, starting: false, error: String((error as Error)?.message ?? error) }),
    );
  };
  const going = tree?.files.filter((f) => !f.secret || send.includes(f.path)) ?? [];
  const secrets = tree?.files.filter((f) => f.secret) ?? [];
  const ready = plan.eligible && Boolean(machine) && Boolean(tree) && !run.starting;
  // The chip that opened the panel is gone, so the focus moves in: Return and Escape work at once.
  const formRef = useRef<HTMLFormElement>(null);
  useEffect(() => {
    const form = formRef.current;
    const first = ["input:checked:not(:disabled)", ".cv-run-elsewhere__run:not(:disabled)", "button:not(:disabled)"]
      .map((selector) => form?.querySelector<HTMLElement>(selector))
      .find(Boolean);
    first?.focus({ preventScroll: true });
  }, []);
  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Escape closes the panel from any of its controls.
    <form
      ref={formRef}
      className="cv-run-elsewhere"
      aria-label={t("runElsewhere.title")}
      onSubmit={(event) => {
        event.preventDefault();
        if (ready) start();
      }}
      onKeyDown={(event) => {
        if (event.key === "Escape") {
          event.stopPropagation();
          close();
        }
      }}
    >
      <div className="cv-run-elsewhere__head">
        <span className="cv-run-elsewhere__title">{t("runElsewhere.title")}</span>
        {tree && (
          <span className="cv-run-elsewhere__base" title={tree.origin}>
            {t("runElsewhere.base", { commit: tree.base.slice(0, 9) })}
          </span>
        )}
      </div>
      {!plan.eligible ? (
        <p className="cv-run-elsewhere__note">
          {plan.unavailable ? t("runElsewhere.unavailable") : t("runElsewhere.stays", { why: plan.why ?? "" })}
        </p>
      ) : plan.machines.length === 0 ? (
        <p className="cv-run-elsewhere__note">{t("runElsewhere.noMachine")}</p>
      ) : (
        <div className="cv-run-elsewhere__machines" role="radiogroup" aria-label={t("runElsewhere.machine")}>
          {plan.machines.map((m) => (
            <label
              key={m.name}
              className="cv-run-elsewhere__machine"
              data-checked={m.name === machine || undefined}
              title={m.ok ? undefined : m.why}
            >
              <input
                type="radio"
                aria-label={m.name}
                name={`run-elsewhere-${toolCallId}`}
                value={m.name}
                checked={m.name === machine}
                disabled={!m.ok}
                onChange={() => update({ machine: m.name })}
              />
              <Icon name="machine.remote" size={CHIP_ICON} row fit />
              <span>{m.name}</span>
            </label>
          ))}
        </div>
      )}
      {plan.eligible && tree && (
        <div className="cv-run-elsewhere__tree">
          <div className="cv-run-elsewhere__group">
            <span className="cv-run-elsewhere__label">{t("runElsewhere.sends")}</span>
            {going.length === 0 ? (
              <span className="cv-run-elsewhere__file is-quiet">{t("runElsewhere.noChanges")}</span>
            ) : (
              going.map((f) => (
                <span key={f.path} className="cv-run-elsewhere__file" data-status={f.status}>
                  <span className="cv-run-elsewhere__status">{f.status}</span>
                  {f.path}
                </span>
              ))
            )}
          </div>
          {secrets.length > 0 && (
            <div className="cv-run-elsewhere__group is-warn">
              <span className="cv-run-elsewhere__label">{t("runElsewhere.secrets")}</span>
              {secrets.map((f) => (
                <label key={f.path} className="cv-run-elsewhere__file">
                  <input
                    type="checkbox"
                    aria-label={f.path}
                    checked={send.includes(f.path)}
                    onChange={(event) =>
                      update({
                        send: event.target.checked ? [...send, f.path] : send.filter((p) => p !== f.path),
                      })
                    }
                  />
                  {f.path}
                  <span className="cv-run-elsewhere__aside">{t("runElsewhere.sendAnyway")}</span>
                </label>
              ))}
            </div>
          )}
          {tree.untrackedTotal > 0 && (
            <div className="cv-run-elsewhere__group is-quiet">
              <span className="cv-run-elsewhere__label">{t("runElsewhere.untracked")}</span>
              {tree.untracked.slice(0, UNTRACKED_SHOWN).map((p) => (
                <span key={p} className="cv-run-elsewhere__file">
                  {p}
                </span>
              ))}
              {tree.untrackedTotal > UNTRACKED_SHOWN && (
                <span className="cv-run-elsewhere__file is-quiet">
                  {t("runElsewhere.more", { count: tree.untrackedTotal - UNTRACKED_SHOWN })}
                </span>
              )}
            </div>
          )}
        </div>
      )}
      {run.error && <p className="cv-run-elsewhere__error">{run.error}</p>}
      <div className="cv-run-elsewhere__actions">
        {/* The shared button (ui/controls.css, which the pane loads): a raw button here drew the
            browser's grey bezel with its key glyph jammed against the label (Leo, 2026-11-11). */}
        <DialogButton
          dialogKey="escape"
          className="ui-button ui-btn cv-run-elsewhere__cancel"
          data-variant="subtle"
          data-size="sm"
          onClick={close}
        >
          {t("runElsewhere.cancel")}
        </DialogButton>
        {plan.eligible && machine && (
          <DialogButton
            dialogKey="return"
            type="submit"
            className="ui-button ui-btn cv-run-elsewhere__run"
            data-variant="solid"
            data-size="sm"
            data-disabled={!ready || undefined}
            disabled={!ready}
          >
            {t("runElsewhere.run", { machine })}
          </DialogButton>
        )}
      </div>
    </form>
  );
}

/** The run's row: where it runs, how it stands, and its output as it arrives. Reads the task's
 * output while it runs and stops reading when it ends or the row goes. */
function RunElsewhereStream({
  runs,
  toolCallId,
  run,
}: {
  runs: Runs;
  toolCallId: string;
  run: Extract<RunState, { phase: "running" | "ended" }>;
}) {
  const t = useT();
  const { taskId, machine } = run;
  const live = run.phase === "running";
  const outputRef = useRef<HTMLPreElement>(null);
  useEffect(() => {
    if (!live) return;
    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    // A row shown again (the transcript is virtual) goes on where its reads stopped.
    const at = runs.store.get(toolCallId);
    let from = at?.phase === "running" ? (at.read ?? 0) : 0;
    let delay = 250;
    let failures = 0;
    const decoder = (at?.phase === "running" && at.decoder) || new TextDecoder();
    const read = () => {
      runs.client.output(taskId, from).then(
        (out) => {
          if (stopped) return;
          failures = 0;
          const text = decodeChunk(decoder, out.data);
          from = out.nextByte;
          const current = runs.store.get(toolCallId);
          if (current?.phase !== "running" || current.taskId !== taskId) return;
          // An ended task is read to its last byte first: one read returns at most 64 KiB.
          const ended = out.state !== "running" && (out.totalBytes === undefined ? !out.data : from >= out.totalBytes);
          runs.store.set(toolCallId, {
            ...current,
            phase: ended ? "ended" : "running",
            output: appendOutput(current.output, text + (ended ? decoder.decode() : "")),
            read: from,
            decoder,
            exitCode: out.exitCode,
            state: out.state,
          });
          if (ended) return;
          delay = nextReadDelay(delay, text.length > 0);
          timer = setTimeout(read, delay);
        },
        () => {
          if (stopped) return;
          // A task acpmux no longer has (a daemon restart, a purged chat) ends the reads.
          failures += 1;
          const current = runs.store.get(toolCallId);
          if (failures >= READ_FAILURES && current?.phase === "running" && current.taskId === taskId) {
            runs.store.set(toolCallId, { ...current, phase: "ended", state: "lost" });
            return;
          }
          delay = nextReadDelay(delay, false);
          timer = setTimeout(read, delay);
        },
      );
    };
    read();
    return () => {
      stopped = true;
      clearTimeout(timer);
    };
  }, [live, runs, taskId, toolCallId]);
  // Follow the end while the reader is at it, as a terminal does.
  useEffect(() => {
    const node = outputRef.current;
    if (!node) return;
    if (node.scrollHeight - node.scrollTop - node.clientHeight < 48) node.scrollTop = node.scrollHeight;
  }, [run.output]);
  const status = live
    ? t("runElsewhere.running", { machine })
    : run.state === "exited" && run.exitCode === 0
      ? t("runElsewhere.finished", { machine })
      : t("runElsewhere.ended", { machine, code: String(run.exitCode ?? run.state ?? "") });
  return (
    <div
      className="cv-run-elsewhere cv-run-elsewhere--run"
      data-state={live ? "running" : run.exitCode === 0 ? "ok" : "failed"}
    >
      <div className="cv-run-elsewhere__head">
        <Icon name="machine.remote" size={CHIP_ICON} row fit />
        <output className={`cv-run-elsewhere__title${live ? " is-live" : ""}`}>{status}</output>
        {live ? (
          <button
            type="button"
            className="cv-run-elsewhere__link"
            onClick={() => void runs.client.stop(taskId).catch(() => undefined)}
          >
            {t("runElsewhere.stop")}
          </button>
        ) : (
          <button
            type="button"
            className="cv-run-elsewhere__link"
            onClick={() => runs.store.set(toolCallId, undefined)}
          >
            {t("runElsewhere.dismiss")}
          </button>
        )}
      </div>
      {run.output && (
        // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- focus the output's scroller to read it with the keys.
        <pre ref={outputRef} className="cv-run-elsewhere__output" tabIndex={0}>
          {run.output}
        </pre>
      )}
    </div>
  );
}
