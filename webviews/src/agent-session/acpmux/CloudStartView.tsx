import React from "react";
import { experimentArm } from "../../experiments/experiment";
import { cloudStartLook } from "./cloudStart.experiment";
import { CLOUD_START_STEPS, type CloudStartProgress, type CloudStartStep } from "./cloudStartProgress";
import { Check, Folder, Spinner } from "./conversation/icons";
import { useT, type StringKey, type Translate } from "./i18n";
import "./cloudStart.css";

const STEP_KEYS: Record<CloudStartStep, StringKey> = {
  machine: "cloudStart.step.machine",
  folder: "cloudStart.step.folder",
  opening: "cloudStart.step.opening",
};

/// A step's words: "Starting your Cloud machine…", "Copying your project…", "Starting Claude Code…".
function stepText(step: CloudStartStep, agent: string | undefined, t: Translate): string {
  return step === "opening" && agent ? t("cloudStart.step.openingAgent", { agent }) : t(STEP_KEYS[step]);
}

type Fact = { id: string; label: string; value: string };

/// What the card says about the start, in order, each only once known.
function facts(start: CloudStartProgress, t: Translate): Fact[] {
  const list: Fact[] = [];
  if (start.folder) list.push({ id: "folder", label: t("composer.folder"), value: start.folder });
  if (start.machine)
    list.push({
      id: "machine",
      label: t("sandbox.vm"),
      value: start.size ? `${start.machine} · ${start.size}` : start.machine,
    });
  if (start.secrets !== undefined)
    list.push({ id: "secrets", label: t("cloudStart.secrets"), value: String(start.secrets) });
  if (start.network)
    list.push({
      id: "network",
      label: t("cloudStart.network"),
      value: t(start.network === "full" ? "cloudStart.networkFull" : "cloudStart.networkLimited"),
    });
  return list;
}

/// A chat starting in Cloud (cloudStartProgress.ts): the person's message, then how the start goes
/// as metadata under it, laid out by the `cloud-start-look` experiment's arm. Working is a spinner;
/// a failure says the host's words (the message stays in the composer).
/// `bubble` false: no message bubble, where the message still shows in its box (the New Tab page).
export function CloudStartView({ start, bubble = true }: { start: CloudStartProgress; bubble?: boolean }) {
  const t = useT();
  const arm = experimentArm(cloudStartLook);
  const known = facts(start, t);
  const failed = start.state === "failed";
  const status = failed
    ? (start.message ?? t("sandbox.failed"))
    : start.step && arm !== "steps"
      ? stepText(start.step, start.agent, t)
      : t("cloudStart.title");
  return (
    <div className="acpmux-cloud-start" data-state={start.state} data-look={arm}>
      {bubble && (
        <div className="cv-user">
          <div className="ui-glass cv-user__bubble selectable">{start.task}</div>
        </div>
      )}
      <output className="acpmux-cloud-start__status" {...(failed ? { role: "alert" } : {})}>
        {!failed && <Spinner size={14} loading />}
        <span>{status}</span>
      </output>
      {arm === "steps" && !failed && <StepList step={start.step} agent={start.agent} home={start.home} t={t} />}
      {known.length > 0 &&
        (arm === "rows" ? (
          <dl className="acpmux-cloud-start__rows">
            {known.map((fact) => (
              <React.Fragment key={fact.id}>
                <dt>{fact.label}</dt>
                <dd>{fact.value}</dd>
              </React.Fragment>
            ))}
          </dl>
        ) : (
          <ul className="acpmux-cloud-start__chips" data-look={arm}>
            {known.map((fact) => (
              <li key={fact.id} data-fact={fact.id}>
                {fact.id === "folder" ? (
                  <Folder size={12} />
                ) : (
                  <span className="acpmux-cloud-start__label">{fact.label}</span>
                )}
                <span>{fact.value}</span>
              </li>
            ))}
          </ul>
        ))}
    </div>
  );
}

/// The `steps` arm: each step done (a check), current (a spinner) or still to come.
function StepList({
  step,
  agent,
  home,
  t,
}: {
  step: CloudStartStep | undefined;
  agent?: string;
  home?: boolean;
  t: Translate;
}) {
  // No project: nothing is copied, so there is no copy step.
  const steps: readonly CloudStartStep[] = home
    ? CLOUD_START_STEPS.filter((name) => name !== "folder")
    : CLOUD_START_STEPS;
  const current = step ? steps.indexOf(step) : -1;
  return (
    <ol className="acpmux-cloud-start__steps">
      {steps.map((name, index) => {
        const state = index < current ? "done" : index === current ? "current" : "next";
        return (
          <li key={name} data-step={state}>
            <span className="acpmux-cloud-start__mark" aria-hidden>
              {state === "done" ? <Check size={12} /> : state === "current" ? <Spinner size={12} loading /> : null}
            </span>
            {stepText(name, agent, t)}
          </li>
        );
      })}
    </ol>
  );
}
