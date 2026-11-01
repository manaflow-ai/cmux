import React, { useEffect, useState } from "react";
import { experimentArm } from "../../experiments/experiment";
import { cloudStartLook } from "./cloudStart.experiment";
import { CLOUD_START_STEPS, type CloudStartProgress, type CloudStartupOperation, type CloudStartupSetup } from "./cloudStartProgress";
import { AlertCircle, Check, ChevronDown, ChevronRight, Folder, Spinner } from "./conversation/icons";
import { useT, type Translate } from "./i18n";
import "./cloudStart.css";

type ChecklistStatus = "done" | "running" | "pending" | "skipped" | "error";
type ChecklistStep = { id: "machine" | "clone" | "setup" | "harness"; label: string; status: ChecklistStatus; duration?: string; detail?: string; logTail?: string; action?: boolean };

function elapsed(startedAt: number | undefined, finishedAt: number | undefined, now = Date.now()): string | undefined {
  if (startedAt === undefined) return undefined;
  const ms = Math.max(0, (finishedAt ?? now) - startedAt);
  if (ms < 1000) return "<1s";
  if (ms < 60_000) return `${Math.round(ms / 100) / 10}s`;
  const seconds = Math.round(ms / 1000);
  return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
}

function operationStatus(operation: CloudStartupOperation | undefined): ChecklistStatus | undefined {
  if (!operation) return undefined;
  return operation.state === "done" ? "done" : operation.state === "failed" ? "error" : operation.state === "running" ? "running" : "pending";
}

function setupStatus(setup: CloudStartupSetup | undefined): ChecklistStatus | undefined {
  if (!setup) return undefined;
  if (setup.state === "skipped") return "skipped";
  if (setup.status === "ready" || setup.state === "done") return "done";
  if (setup.status === "failed" || setup.state === "failed") return "error";
  if (setup.status === "building" || setup.state === "running") return "running";
  return "pending";
}

function cloneDetail(operation: CloudStartupOperation | undefined, t: Translate): string | undefined {
  if (!operation) return undefined;
  const parts = [operation.phase === "cached" ? t("cloudStartup.cached") : operation.phase];
  const progress = operation.progress;
  if (progress?.objects !== undefined && progress.totalObjects !== undefined) parts.push(`${progress.objects}/${progress.totalObjects} objects`);
  if (progress?.receivedBytes !== undefined) parts.push(`${Math.round(progress.receivedBytes / 1024)} KB`);
  return parts.filter(Boolean).join(" · ") || operation.error;
}

const DEFAULT_STARTUP_STRINGS: Record<string, string> = {
  "cloudStartup.machine": "Set up a Cloud machine", "cloudStartup.clone": "Clone repository", "cloudStartup.setup": "Run setup script", "cloudStartup.setupHint": "Add a setup script to install dependencies and configure your environment.", "cloudStartup.cached": "cached", "cloudStartup.harness": "Started {harness}",
};
export function startupChecklist(start: CloudStartProgress, t: Translate = (key, values = {}) => (DEFAULT_STARTUP_STRINGS[key] ?? key).replace("{harness}", String(values.harness ?? "Harness")), now = Date.now()): ChecklistStep[] {
  const oldStep = start.step ? CLOUD_START_STEPS.indexOf(start.step) : -1;
  const failedStep = start.state === "failed"
    ? (oldStep === 0 ? "machine" : oldStep === 1 ? "clone" : oldStep === 2 ? "harness" : start.clone?.state === "running" || start.clone?.state === "failed" ? "clone" : start.setup?.state === "running" || start.setup?.state === "failed" ? "setup" : "machine")
    : undefined;
  const machine: ChecklistStep = { id: "machine", label: t("cloudStartup.machine"), status: failedStep === "machine" ? "error" : oldStep > 0 || start.initialized ? "done" : oldStep === 0 ? "running" : "pending", duration: elapsed(start.machineStartedAt, start.machineFinishedAt, now) };
  const hasRepository = start.hasRepository ?? (Boolean(start.repository || start.folder || start.clone) && !start.home);
  const cloneStatus = operationStatus(start.clone);
  const stoppedCloneStatus = start.state === "failed" && failedStep !== "clone" && cloneStatus === "running" ? "pending" : cloneStatus;
  const clone: ChecklistStep = { id: "clone", label: t("cloudStartup.clone"), status: !hasRepository ? "skipped" : failedStep === "clone" ? "error" : stoppedCloneStatus ?? (oldStep > 1 ? "done" : oldStep === 1 ? "running" : "pending"), duration: elapsed(start.clone?.startedAt, start.clone?.finishedAt, now), ...((cloneDetail(start.clone, t) || start.clone?.error) ? { detail: cloneDetail(start.clone, t) || start.clone?.error } : {}) };
  const hasScript = start.setup?.hasScript;
  const setupState = setupStatus(start.setup);
  const stoppedSetupState = start.state === "failed" && failedStep !== "setup" && setupState === "running" ? "pending" : setupState;
  const setup: ChecklistStep = { id: "setup", label: t("cloudStartup.setup"), status: hasScript === false ? "skipped" : failedStep === "setup" ? "error" : stoppedSetupState ?? (start.initialized ? "done" : "pending"), duration: elapsed(start.setup?.startedAt, start.setup?.finishedAt, now), ...(start.setup?.status === "ready" ? { detail: t("cloudStartup.cached") } : {}), ...((start.setup?.logTail || start.setup?.error) ? { detail: start.setup.logTail || start.setup.error, ...(start.setup.logTail ? { logTail: start.setup.logTail } : {}) } : {}), ...(hasScript === false ? { detail: t("cloudStartup.setupHint"), action: true } : {}) };
  const harness: ChecklistStep = { id: "harness", label: t("cloudStartup.harness", { harness: start.agent || "Harness" }), status: failedStep === "harness" ? "error" : start.initialized ? "done" : oldStep === 2 ? "running" : "pending", duration: elapsed(start.harnessStartedAt, start.harnessFinishedAt, now) };
  return [machine, clone, setup, harness];
}

function mark(step: ChecklistStep, t: Translate) {
  if (step.status === "done") return <><Check size={16} /><span className="visually-hidden">{t("cloudStartup.state.done")}</span></>;
  if (step.status === "running") return <><Spinner size={16} loading /><span className="visually-hidden">{t("cloudStartup.state.running")}</span></>;
  if (step.status === "error") return <><AlertCircle size={16} /><span className="visually-hidden">{t("cloudStartup.state.error")}</span></>;
  if (step.status === "skipped") return <><span className="acpmux-cloud-start__skip-mark" aria-hidden /><span className="visually-hidden">{t("cloudStartup.state.skipped")}</span></>;
  return <><span className="acpmux-cloud-start__pending-mark" aria-hidden /><span className="visually-hidden">{t("cloudStartup.state.pending")}</span></>;
}

type Fact = { id: string; label: string; value: string };
function facts(start: CloudStartProgress, t: Translate): Fact[] {
  const list: Fact[] = [];
  if (start.folder) list.push({ id: "folder", label: t("composer.folder"), value: start.folder });
  if (start.machine) list.push({ id: "machine", label: t("sandbox.vm"), value: start.size ? `${start.machine} · ${start.size}` : start.machine });
  if (start.secrets !== undefined) list.push({ id: "secrets", label: t("cloudStart.secrets"), value: String(start.secrets) });
  if (start.network) list.push({ id: "network", label: t("cloudStart.network"), value: t(start.network === "full" ? "cloudStart.networkFull" : "cloudStart.networkLimited") });
  return list;
}

export function CloudStartView({ start, bubble = true, onOpenEnvironment }: { start: CloudStartProgress; bubble?: boolean; onOpenEnvironment?: (options: { environmentId?: string; repository?: string; section: "script" }) => void }) {
  const t = useT();
  const arm = experimentArm(cloudStartLook);
  const failed = start.state === "failed";
  const [expanded, setExpanded] = useState(!start.initialized);
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (start.initialized || start.state === "failed") return;
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [start.initialized, start.state]);
  useEffect(() => { setExpanded(start.initialized !== true); }, [start.initialized]);
  const rows = startupChecklist(start, t, now);
  const known = facts(start, t);
  const openEnvironment = () => {
    const options = { ...(start.environmentId ? { environmentId: start.environmentId } : {}), ...(start.repository ? { repository: start.repository } : {}), section: "script" as const };
    if (onOpenEnvironment) onOpenEnvironment(options);
    else window.dispatchEvent(new CustomEvent("cmux:open-cloud-environment", { detail: options }));
  };
  return <section className="acpmux-cloud-start" data-state={start.state} data-look={arm} data-initialized={start.initialized ? "true" : undefined}>
    {bubble && <div className="cv-user"><div className="ui-glass cv-user__bubble selectable">{start.task}</div></div>}
    {!failed && !start.initialized && <output className="acpmux-cloud-start__status"><Spinner size={14} loading /><span>{t("cloudStart.title")}</span></output>}
    <div className="acpmux-cloud-start__card">
      <button type="button" className="acpmux-cloud-start__summary" aria-expanded={expanded} onClick={() => setExpanded((value) => !value)}><span>{start.initialized ? t("cloudStartup.initialized") : t("cloudStartup.title")}</span>{expanded ? <ChevronDown size={14} /> : start.initialized ? <span aria-hidden>›</span> : <ChevronRight size={14} />}</button>
      {expanded && <div className="acpmux-cloud-start__checklist" aria-label="Cloud startup checklist">{rows.map((step) => <div key={step.id} className="acpmux-cloud-start__row" data-status={step.status} data-step-id={step.id}><span className="acpmux-cloud-start__mark">{mark(step, t)}</span><span className="acpmux-cloud-start__row-label">{step.label}</span>{step.duration && <time className="acpmux-cloud-start__time">{step.duration}</time>}{step.id === "setup" && step.action ? <span className="acpmux-cloud-start__detail">{onOpenEnvironment ? <button type="button" className="acpmux-cloud-start__link" onClick={openEnvironment}>{t("cloudStartup.setupHint")}</button> : t("cloudStartup.setupHint")}</span> : step.detail ? <span className={`acpmux-cloud-start__detail${step.logTail ? " acpmux-cloud-start__log-tail" : ""}`}>{step.detail}</span> : null}</div>)}</div>}
    </div>
    {failed && <output className="acpmux-cloud-start__status" role="alert">{start.message ?? t("sandbox.failed")}</output>}
    {known.length > 0 && <ul className="acpmux-cloud-start__chips" data-look={arm}>{known.map((fact) => <li key={fact.id} data-fact={fact.id}>{fact.id === "folder" ? <Folder size={12} /> : <span className="acpmux-cloud-start__label">{fact.label}</span>}<span>{fact.value}</span></li>)}</ul>}
    {arm === "steps" && !failed && <ol className="acpmux-cloud-start__legacy-steps" aria-hidden>{CLOUD_START_STEPS.map((name, index) => { const current = start.step ? CLOUD_START_STEPS.indexOf(start.step) : -1; const state = index < current ? "done" : index === current ? "current" : "next"; return <li key={name} data-step={state}>{name}</li>; })}</ol>}
  </section>;
}
