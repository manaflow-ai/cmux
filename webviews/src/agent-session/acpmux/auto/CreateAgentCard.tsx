// RFD 0080 "The create flow": what should the agent do, Project, Agent, the place button (RFD 0078's,
// passed in as a slot) and Start. There is no machine field: AUTO chooses the computer beside the
// model's first answer. Presentation only; the page owns the values and what Start does.
import "./computerAuto.css";
import type { ReactNode } from "react";
import { useT } from "../i18n";

export function CreateAgentCard({
  task,
  project,
  agent,
  placeButton,
  onTask,
  onProject,
  onAgent,
  onStart,
}: {
  task: string;
  project: string;
  agent: string;
  /// RFD 0078's button, drawn by the page.
  placeButton: ReactNode;
  onTask(value: string): void;
  onProject(): void;
  onAgent(): void;
  onStart(): void;
}) {
  const t = useT();
  return (
    <section className="acpmux-create-card" aria-label={t("computer.create.prompt")}>
      <label className="acpmux-create-prompt">
        <span className="acpmux-create-label">{t("computer.create.prompt")}</span>
        <textarea
          className="acpmux-create-task"
          rows={2}
          aria-label={t("computer.create.prompt")}
          value={task}
          placeholder={t("computer.create.placeholder")}
          onChange={(event) => onTask(event.currentTarget.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && (event.metaKey || event.ctrlKey) && task.trim()) onStart();
          }}
        />
      </label>
      <div className="acpmux-create-foot">
        <button type="button" className="acpmux-create-field" onClick={onProject}>
          <span className="acpmux-create-field-label">{t("computer.create.project")}</span>
          <span className="acpmux-create-field-value">{project}</span>
          <span aria-hidden="true">▾</span>
        </button>
        <button type="button" className="acpmux-create-field" onClick={onAgent}>
          <span className="acpmux-create-field-label">{t("computer.create.agent")}</span>
          <span className="acpmux-create-field-value">{agent}</span>
          <span aria-hidden="true">▾</span>
        </button>
        <span className="acpmux-create-spacer" />
        {placeButton}
        <button type="button" className="acpmux-create-start" disabled={!task.trim()} onClick={onStart}>
          {t("computer.create.start")} <span aria-hidden="true">⏎</span>
        </button>
      </div>
    </section>
  );
}
