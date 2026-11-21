// A repo tour reply (tourModel.ts): a closed ```cmux-tour fence drawn as one quiet card in the
// transcript. What the project is, its main modules as path chips, how to run it, and three first
// tasks with Start. A fence still streaming draws as one "Writing the tour" line in the same card.
import { useState } from "react";
import { PathChip } from "../chips/LinkChips";
import { useTranscriptReadOnly } from "../conversation/readOnly";
import { useT } from "../i18n";
import { errorMessage } from "../transportErrors";
import type { Tour, TourTask } from "./tourModel";
import "./tour.css";

/// Starts one task (App.tsx `chat.tour.start`): a worktree of the chat's folder and a chat there.
export type StartTourTask = (task: TourTask) => Promise<unknown>;

/// The map glyph the offer and the card share.
export function TourGlyph({ size = 16 }: { size?: number }) {
  return (
    <svg
      className="acpmux-tour-glyph"
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M1.75 3.75 5.5 2.25l5 1.5 3.75-1.5v10l-3.75 1.5-5-1.5-3.75 1.5z" />
      <path d="M5.5 2.25v10M10.5 3.75v10" />
    </svg>
  );
}

export function TourCard({ tour, onStart }: { tour?: Tour; onStart?: StartTourTask }) {
  const t = useT();
  if (!tour)
    return (
      <div className="acpmux-tour" data-pending="">
        <div className="acpmux-tour-head">
          <TourGlyph />
          <span>{t("tour.writing")}</span>
        </div>
      </div>
    );
  return (
    <section className="acpmux-tour" aria-label={t("tour.title")}>
      <div className="acpmux-tour-head">
        <TourGlyph />
        <span>{t("tour.title")}</span>
        {tour.head && <span className="acpmux-tour-head-sha">{tour.head.slice(0, 7)}</span>}
      </div>
      <p className="acpmux-tour-summary">{tour.summary}</p>
      {tour.modules.length > 0 && (
        <>
          <h3 className="acpmux-tour-label">{t("tour.modules")}</h3>
          <ul className="acpmux-tour-list">
            {tour.modules.map((module) => (
              <li key={module.path} className="acpmux-tour-item">
                <span className="acpmux-tour-key">
                  <PathChip path={module.path} written={module.path} />
                </span>
                {module.about && <span className="acpmux-tour-about">{module.about}</span>}
              </li>
            ))}
          </ul>
        </>
      )}
      {tour.run.length > 0 && (
        <>
          <h3 className="acpmux-tour-label">{t("tour.run")}</h3>
          <ul className="acpmux-tour-list">
            {tour.run.map((command) => (
              <li key={command.command} className="acpmux-tour-item">
                <code className="cv-code acpmux-tour-key">{command.command}</code>
                {command.about && <span className="acpmux-tour-about">{command.about}</span>}
              </li>
            ))}
          </ul>
        </>
      )}
      {tour.tasks.length > 0 && (
        <>
          <h3 className="acpmux-tour-label">{t("tour.tasks")}</h3>
          <ul className="acpmux-tour-list">
            {tour.tasks.map((task) => (
              <TourTaskRow key={task.title} task={task} onStart={onStart} />
            ))}
          </ul>
        </>
      )}
    </section>
  );
}

type TaskState = { state: "idle" } | { state: "starting" } | { state: "started" } | { state: "failed"; reason: string };

function TourTaskRow({ task, onStart }: { task: TourTask; onStart?: StartTourTask }) {
  const t = useT();
  const readOnly = useTranscriptReadOnly();
  const [run, setRun] = useState<TaskState>({ state: "idle" });
  const start = () => {
    if (!onStart || run.state === "starting" || run.state === "started") return;
    setRun({ state: "starting" });
    onStart(task).then(
      () => setRun({ state: "started" }),
      (error: unknown) => setRun({ state: "failed", reason: errorMessage(error) || t("tour.startFailedUnknown") }),
    );
  };
  return (
    <li className="acpmux-tour-task">
      <div className="acpmux-tour-task-head">
        <span className="acpmux-tour-task-title">{task.title}</span>
        {onStart && !readOnly && (
          <button
            type="button"
            className="acpmux-tour-start"
            data-state={run.state}
            disabled={run.state === "starting" || run.state === "started"}
            onClick={start}
            title={t("tour.startTitle")}
          >
            {run.state === "starting"
              ? t("tour.starting")
              : run.state === "started"
                ? t("tour.started")
                : t("tour.start")}
          </button>
        )}
      </div>
      <p className="acpmux-tour-task-prompt">{task.prompt}</p>
      {run.state === "failed" && (
        <p className="acpmux-tour-task-error" role="alert">
          {t("tour.startFailed", { reason: run.reason })}
        </p>
      )}
    </li>
  );
}
