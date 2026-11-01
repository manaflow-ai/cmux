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

export function startupChecklist(start: CloudStartProgress): ChecklistStep[] {
  const oldStep = start.step ? CLOUD_START_STEPS.indexOf(start.step) : -1;
  const machine: ChecklistStep = { id: "machine", label: "Set up a Cloud machine", status: start.state === "failed" && oldStep < 0 ? "error" : oldStep > 0 || start.initialized ? "done" : oldStep === 0 ? "running" : "pending", duration: elapsed(start.machineStartedAt, start.machineFinishedAt) };
  const hasRepository = start.hasRepository ?? Boolean(start.repository || start.folder) && !start.home;
  const cloneStatus = operationStatus(start.clone);
  const clone: ChecklistStep = { id: "clone", label: "Clone repository", status: !hasRepository ? "skipped" : cloneStatus ?? (oldStep > 1 ? "done" : oldStep === 1 ? "running" : "pending"), duration: elapsed(start.clone?.startedAt, start.clone?.finishedAt), ...(start.clone?.error ? { detail: start.clone.error } : {}) };
  const hasScript = start.setup?.hasScript;
  const setup: ChecklistStep = { id: "setup", label: "Run setup script", status: hasScript === false ? "skipped" : setupStatus(start.setup) ?? (start.initialized ? "done" : "pending"), duration: elapsed(start.setup?.startedAt, start.setup?.finishedAt), ...(start.setup?.status === "ready" ? { detail: "cached" } : {}), ...(start.setup?.logTail ? { detail: start.setup.logTail, logTail: start.setup.logTail } : {}), ...(hasScript === false ? { detail: "Add a setup script to install dependencies and configure your environment.", action: true } : {}) };
  const harness: ChecklistStep = { id: "harness", label: `Started ${start.agent || "Harness"}`, status: start.state === "failed" ? "error" : start.initialized ? "done" : oldStep === 2 ? "running" : "pending", duration: elapsed(start.harnessStartedAt, start.harnessFinishedAt) };
  return [machine, clone, setup, harness];
}

function mark(step: ChecklistStep) {
  if (step.status === "done") return <Check size={16} />;
  if (step.status === "running") return <Spinner size={16} loading />;
  if (step.status === "error") return <AlertCircle size={16} />;
  if (step.status === "skipped") return <span className="acpmux-cloud-start__skip-mark" aria-hidden />;
  return <span className="acpmux-cloud-start__pending-mark" aria-hidden />;
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
  useEffect(() => { if (start.initialized) setExpanded(false); }, [start.initialized]);
  const rows = startupChecklist(start);
  const known = facts(start, t);
  const openEnvironment = () => {
    const options = { ...(start.environmentId ? { environmentId: start.environmentId } : {}), ...(start.repository ? { repository: start.repository } : {}), section: "script" as const };
    if (onOpenEnvironment) onOpenEnvironment(options);
    else window.dispatchEvent(new CustomEvent("cmux:open-cloud-environment", { detail: options }));
  };
  return <section className="acpmux-cloud-start" data-state={start.state} data-look={arm} data-initialized={start.initialized ? "true" : undefined}>
    {bubble && !failed && <div className="cv-user"><div className="ui-glass cv-user__bubble selectable">{start.task}</div></div>}
    {!failed && !start.initialized && <output className="acpmux-cloud-start__status"><Spinner size={14} loading /><span>Starting in Cloud</span></output>}
    <div className="acpmux-cloud-start__card">
      <button type="button" className="acpmux-cloud-start__summary" aria-expanded={expanded} onClick={() => setExpanded((value) => !value)}><span>{start.initialized ? "Initialized session" : "Initializing session"}</span>{expanded ? <ChevronDown size={14} /> : <ChevronRight size={14} />}</button>
      {expanded && <div className="acpmux-cloud-start__checklist" aria-label="Cloud startup checklist">{rows.map((step) => <div key={step.id} className="acpmux-cloud-start__row" data-step={step.status} data-step-id={step.id}><span className="acpmux-cloud-start__mark" aria-hidden>{mark(step)}</span><span className="acpmux-cloud-start__row-label">{step.label}</span>{step.duration && <time className="acpmux-cloud-start__time">{step.duration}</time>}{step.id === "setup" && step.action ? <span className="acpmux-cloud-start__detail"><button type="button" className="acpmux-cloud-start__link" onClick={openEnvironment}>Add a setup script</button> to install dependencies and configure your environment.</span> : step.detail ? <span className={`acpmux-cloud-start__detail${step.logTail ? " acpmux-cloud-start__log-tail" : ""}`}>{step.detail}</span> : null}</div>)}</div>}
    </div>
    {failed && <output className="acpmux-cloud-start__status" role="alert">{start.message ?? t("sandbox.failed")}</output>}
    {known.length > 0 && <ul className="acpmux-cloud-start__chips" data-look={arm}>{known.map((fact) => <li key={fact.id} data-fact={fact.id}>{fact.id === "folder" ? <Folder size={12} /> : <span className="acpmux-cloud-start__label">{fact.label}</span>}<span>{fact.value}</span></li>)}</ul>}
    {arm === "steps" && !failed && <ol className="acpmux-cloud-start__legacy-steps" aria-hidden>{CLOUD_START_STEPS.map((name, index) => { const current = start.step ? CLOUD_START_STEPS.indexOf(start.step) : -1; const state = index < current ? "done" : index === current ? "current" : "next"; return <li key={name} data-step={state}>{state === "done" ? <Check size={12} /> : state === "current" ? <Spinner size={12} loading /> : null}{name}</li>; })}</ol>}
  </section>;
}
