// Settings > General > Customize cmux: a checklist of the ways to make cmux yours (theme, look,
// shortcuts, notifications, agents, MCP, GitHub, the sidebar, ...), with the person's progress.
// Leo, 2026-11-22: "a customizations checklist. actually, this needs to be SOMEWHERE as a default.
// not just for me." So it is on for everyone (`customize.checklist.enabled` defaults to true), it is
// General's first card (General is where Settings opens), every step opens where it is done, and
// Dismiss puts it away until Settings > General's switch brings it back.
//
// Rust owns the steps, their routes and every done state (cmux-customize `checklist.rs`, read
// through `cmux --json customize checklist`): a step is done when a setting it watches differs from
// its default, a binding or library entry exists, a connection the page reports is there, or the
// person checked it off. This card draws the answer and writes two settings keys, nothing else.
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { Button } from "../../../ui/Button";
import { DismissButton } from "../../../ui/DismissButton";
import { useSettingsRouter, useSettingsState, useStore } from "../context";
import { CHECKLIST_DONE_KEY, CHECKLIST_ENABLED_KEY, checklistFacts, toggledDone } from "../customizeProgress";
import { Icon } from "../icons";
import type { Checklist, ChecklistStep } from "../ops";
import { checklistKey, checklistQuery } from "../sectionQueries";
import { t, text } from "../strings";

/** How the checklist draws (gallery `settings.customize-progress-layouts`). `card`, the shipped one,
 * is a Settings card: progress, then the steps left with the rest a click away. `newTab` is one line
 * with the next step, for the New Tab page; `ring` is a sidebar footer ring with its count; `sheet` is
 * a first-run sheet listing every step at once. */
export type ProgressLayout = "card" | "newTab" | "ring" | "sheet";

/** The page's gestures on the checklist. */
export type ProgressActions = {
  onOpen: (route: string) => void;
  onCheck: (id: string, done: boolean) => void;
  onDismiss: () => void;
};

/** Steps the card shows before Show All: the next few left to do. */
const SHOWN = 5;

export function CustomizeProgressCard() {
  const store = useStore();
  const router = useSettingsRouter();
  const state = useSettingsState();
  const queryClient = useQueryClient();
  const query = useQuery(checklistQuery(store));
  // A settings change or a connection the page learns of re-asks; the last answer stays drawn meanwhile.
  const asked = `${state.revision} ${checklistFacts(state).join(" ")}`;
  const last = useRef(asked);
  useEffect(() => {
    if (last.current === asked) return;
    last.current = asked;
    void queryClient.invalidateQueries({ queryKey: checklistKey });
  }, [asked, queryClient]);
  const checklist = query.data ?? null;
  // No CLI in this build, or the person dismissed it: nothing to draw.
  if (!checklist || state.rows.get(CHECKLIST_ENABLED_KEY)?.value === false) return null;
  const actions: ProgressActions = {
    onOpen: (route) => void router.history.push(route),
    onCheck: (id, done) =>
      void store.set(CHECKLIST_DONE_KEY, toggledDone(state.rows.get(CHECKLIST_DONE_KEY)?.value, id, done)),
    onDismiss: () => void store.set(CHECKLIST_ENABLED_KEY, false),
  };
  return <CustomizeProgressView checklist={checklist} layout="card" actions={actions} />;
}

export function CustomizeProgressView({
  checklist,
  layout,
  actions,
}: {
  checklist: Checklist;
  layout: ProgressLayout;
  actions: ProgressActions;
}) {
  if (!checklist.enabled) return null;
  const progress = t("settingsPage.customizeProgress.progress", checklist.done, checklist.total);
  const next = checklist.steps.find((step) => step.id === checklist.next) ?? null;
  const dismiss = <DismissButton label={t("settingsPage.customizeProgress.dismiss")} onDismiss={actions.onDismiss} />;
  if (layout === "newTab" || layout === "ring") {
    return (
      <section
        className={`customize-progress customize-progress--${layout}`}
        data-card="customizeProgress"
        data-layout={layout}
        aria-label={t("settingsPage.customizeProgress.title")}
      >
        {layout === "ring" ? <Ring done={checklist.done} total={checklist.total} /> : null}
        <div className="customize-progress__summary">
          <span className="customize-progress__title">{t("settingsPage.customizeProgress.title")}</span>
          <span className="customize-progress__count" data-progress>
            {progress}
          </span>
        </div>
        {next ? (
          <Button
            variant="ghost"
            size="sm"
            className="customize-progress__next"
            onClick={() => actions.onOpen(next.route)}
          >
            {t("settingsPage.customizeProgress.next", text(next.title))}
          </Button>
        ) : null}
        {dismiss}
      </section>
    );
  }
  return (
    <CardBody
      checklist={checklist}
      layout={layout}
      progress={progress}
      dismiss={dismiss}
      actions={actions}
      key={layout}
    />
  );
}

function CardBody({
  checklist,
  layout,
  progress,
  dismiss,
  actions,
}: {
  checklist: Checklist;
  layout: "card" | "sheet";
  progress: string;
  dismiss: ReactNode;
  actions: ProgressActions;
}) {
  const [all, setAll] = useState(layout === "sheet");
  const left = checklist.steps.filter((step) => !step.done);
  const shown = all ? checklist.steps : left.slice(0, SHOWN);
  return (
    <section
      className={`group customize-progress customize-progress--${layout}`}
      data-card="customizeProgress"
      data-layout={layout}
      aria-labelledby="customize-progress-title"
    >
      <header className="customize-progress__head">
        <div className="customize-progress__summary">
          <h2 className="group-title" id="customize-progress-title">
            {t("settingsPage.customizeProgress.title")}
          </h2>
          <span className="customize-progress__count" data-progress>
            {progress}
          </span>
        </div>
        {dismiss}
      </header>
      <Bar done={checklist.done} total={checklist.total} />
      <p className="customize-progress__detail">
        {checklist.next ? t("settingsPage.customizeProgress.detail") : t("settingsPage.customizeProgress.allDone")}
      </p>
      {shown.length > 0 ? (
        <ul className="customize-progress__steps">
          {shown.map((step) => (
            <StepRow key={step.id} step={step} actions={actions} />
          ))}
        </ul>
      ) : null}
      {layout === "card" && checklist.steps.length > shown.length ? (
        <Button variant="ghost" size="sm" className="customize-progress__more" onClick={() => setAll(true)}>
          {t("settingsPage.customizeProgress.showAll", checklist.total)}
        </Button>
      ) : null}
      {layout === "card" && all && left.length > SHOWN ? (
        <Button variant="ghost" size="sm" className="customize-progress__more" onClick={() => setAll(false)}>
          {t("settingsPage.customizeProgress.showLess")}
        </Button>
      ) : null}
    </section>
  );
}

function StepRow({ step, actions }: { step: ChecklistStep; actions: ProgressActions }) {
  // A step done by a setting or a connection is the app's own fact: its check cannot be taken back here.
  const derived = step.done && step.done_by !== "checked";
  const title = text(step.title);
  return (
    <li className="customize-progress__step" data-step={step.id} data-done={step.done ? "" : undefined}>
      <label className="customize-progress__check">
        <input
          type="checkbox"
          checked={step.done}
          aria-label={title}
          disabled={derived}
          onChange={(event) => actions.onCheck(step.id, event.currentTarget.checked)}
        />
        {step.done ? <Icon name="check" /> : null}
      </label>
      <div className="customize-progress__words">
        <span className="customize-progress__step-title">{title}</span>
        <span className="row-help">{text(step.detail)}</span>
      </div>
      <Button
        variant="ghost"
        size="sm"
        className="customize-progress__open"
        data-step-open={step.id}
        onClick={() => actions.onOpen(step.route)}
      >
        {t("settingsPage.customizeProgress.open")}
      </Button>
    </li>
  );
}

function Bar({ done, total }: { done: number; total: number }) {
  return <progress className="customize-progress__bar" max={total || 1} value={done} />;
}

function Ring({ done, total }: { done: number; total: number }) {
  const r = 9;
  const length = 2 * Math.PI * r;
  return (
    <svg className="customize-progress__ring" viewBox="0 0 24 24" width="24" height="24" aria-hidden="true">
      <circle cx="12" cy="12" r={r} className="customize-progress__ring-track" />
      <circle
        cx="12"
        cy="12"
        r={r}
        className="customize-progress__ring-fill"
        strokeDasharray={length}
        strokeDashoffset={length * (1 - (total ? done / total : 0))}
        transform="rotate(-90 12 12)"
      />
    </svg>
  );
}
