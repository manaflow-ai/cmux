import { useState } from "react";
import { intl } from "../../../ui/intl";
import { useT, type Translate } from "../i18n";
import { AlertCircle, Expand } from "./icons";
import {
  PLAN_NAMES,
  PROJECT_NAMES,
  isWarning,
  type AutoSizeRow,
  type First,
  type ResizeAction,
  type Size,
  type WarningRow,
} from "./resizeRow";
import "./ResizeRow.css";

/// The row's design arms (the gallery's compare): `card` is the failed turn's card with a caution
/// mark; `rail` its quieter rail arm; `line` one sentence and the buttons on a line under it.
export type ResizeRowLook = "card" | "rail" | "line";

const usd = (cents: number) =>
  intl
    .NumberFormat(undefined, {
      style: "currency",
      currency: "USD",
      minimumFractionDigits: cents >= 10_000 ? 0 : 2,
      maximumFractionDigits: cents >= 10_000 ? 0 : 2,
    })
    .format(cents / 100);
const wholeUsd = (cents: number) =>
  intl.NumberFormat(undefined, { style: "currency", currency: "USD", maximumFractionDigits: 0 }).format(cents / 100);
const num = (n: number) => intl.NumberFormat(undefined, { maximumFractionDigits: 1 }).format(n);

/// The first button's words: Resize now, or the upgrade the plan's ceiling asks for.
function firstLabel(t: Translate, first: First) {
  return first.kind === "resize"
    ? t("resize.action.resize")
    : t("resize.action.upgrade", { plan: PLAN_NAMES[first.plan], vcpu: first.to.vcpu, mem: first.to.memGiB });
}

/// The row's sentence: why the machine is too small, in acpmux's numbers.
function warningSentence(t: Translate, row: WarningRow): string {
  const why = row.why;
  if (why.kind === "project") {
    const project = PROJECT_NAMES[why.project];
    const has =
      why.project === "llvm"
        ? t("resize.project.llvm", { free: why.diskFreeGb })
        : t("resize.project.needs", {
            project,
            disk: why.needsDiskGb,
            memory: why.needsMemoryGb ?? 0,
            free: why.diskFreeGb,
            has: why.memoryGb,
          });
    if (
      why.hoursHere === undefined ||
      why.hoursBurst === undefined ||
      why.burstCents === undefined ||
      why.burstVcpu === undefined
    )
      return has;
    return `${has} ${t("resize.project.time", {
      here: num(why.hoursHere),
      burst: num(why.hoursBurst),
      cost: wholeUsd(why.burstCents),
      vcpu: why.burstVcpu,
    })}`;
  }
  if (why.kind === "bigCheckout")
    return t("resize.bigCheckout", {
      command: why.command,
      checkout: num(why.checkoutGib),
      free: num(why.memoryFreeGib),
      vcpu: row.now.vcpu,
    });
  return why.busyMinutes === null
    ? t("resize.pressure.memory", { used: num(why.memUsedGib), total: num(why.memTotalGib) })
    : t("resize.pressure.both", {
        used: num(why.memUsedGib),
        total: num(why.memTotalGib),
        vcpu: row.now.vcpu,
        minutes: why.busyMinutes,
      });
}

/// The line under the buttons: what the first one costs and when it goes back.
function firstHint(t: Translate, first: First, back: Size) {
  return first.kind === "resize"
    ? t("resize.hint.resize", {
        vcpu: first.to.vcpu,
        mem: first.to.memGiB,
        rate: usd(first.hourlyCents),
        backVcpu: back.vcpu,
        backMem: back.memGiB,
      })
    : t("resize.hint.upgrade", { plan: PLAN_NAMES[first.plan], rate: usd(first.hourlyCents) });
}

function autoSizeSentence(t: Translate, row: AutoSizeRow) {
  const reason = t(`resize.reason.${row.reason}`);
  const size = { vcpu: row.to.vcpu, mem: row.to.memGiB, rate: usd(row.hourlyCents), reason };
  if (row.act === "grew") return t("resize.autosize.grew", size);
  if (row.act === "shrank") return t("resize.autosize.shrank", size);
  return t("resize.autosize.held", size);
}

/// One row in the chat from the VM, not the agent (RFD 0133, "What the person sees"): the warning
/// before or during a job too big for this machine, with Resize now (or the plan's upgrade), Run it
/// on a build machine and Carry on; or AutoSize's notice that the machine grew, shrank or was held at
/// the plan's limit, with Undo at next pause after a grow. Every number and button comes from acpmux
/// (`resize_row.rs`); a click hands the action back (`onAction`), which calls the resize route,
/// `cmux vm run --sync` or the upgrade.
export function ResizeRow({
  row,
  onAction,
  look = "card",
}: {
  row: WarningRow | AutoSizeRow;
  onAction(action: ResizeAction): void;
  look?: ResizeRowLook;
}) {
  const t = useT();
  const [done, setDone] = useState<ResizeAction["kind"] | undefined>();
  const act = (action: ResizeAction) => {
    setDone(action.kind);
    onAction(action);
  };
  if (done === "carryOn") return null;
  const warning = isWarning(row);
  const sentence = warning ? warningSentence(t, row) : autoSizeSentence(t, row);
  const first = warning ? row.first : row.upgrade;
  const firstAction = (f: First): ResizeAction =>
    f.kind === "resize" ? { kind: "resize", to: f.to } : { kind: "upgrade", plan: f.plan };
  const Mark = warning || row.act === "heldAtPlanLimit" ? AlertCircle : Expand;
  return (
    <div
      className={`cv-turn-note cv-turn-error cv-turn-error--${look === "line" ? "note" : look} cv-resize-row`}
      data-resize-look={look}
      data-resize-kind={warning ? "warning" : row.act}
      role={warning ? "alert" : "status"}
    >
      <span className="cv-turn-error__cause">
        {look !== "line" && (
          <Mark size={look === "card" ? 16 : 14} className="cv-turn-error__icon cv-resize-row__icon" />
        )}
        <span className="text-fg">{sentence}</span>
      </span>
      {(first || warning || row.undoAtPause) && (
        <span className="cv-turn-error__actions">
          {first && (
            <button
              type="button"
              className="cv-turn-auth-action cv-turn-error__primary"
              disabled={done !== undefined}
              onClick={() => act(firstAction(first))}
            >
              {firstLabel(t, first)}
            </button>
          )}
          {warning && (
            <>
              <button
                type="button"
                className="cv-turn-auth-action"
                disabled={done !== undefined}
                onClick={() => act({ kind: "buildMachine" })}
              >
                {t("resize.action.buildMachine")}
              </button>
              <button type="button" className="cv-turn-auth-action" onClick={() => act({ kind: "carryOn" })}>
                {t("resize.action.carryOn")}
              </button>
            </>
          )}
          {!warning && row.undoAtPause && (
            <button
              type="button"
              className="cv-turn-auth-action"
              disabled={done === "undoAtPause"}
              onClick={() => act({ kind: "undoAtPause", to: row.from })}
            >
              {done === "undoAtPause"
                ? t("resize.undoQueued", { vcpu: row.from.vcpu, mem: row.from.memGiB })
                : t("resize.action.undoAtPause")}
            </button>
          )}
        </span>
      )}
      {first && look !== "line" && (
        <span className="cv-resize-row__hint text-detail text-dim">
          {firstHint(t, first, warning ? row.backTo : row.from)}
        </span>
      )}
    </div>
  );
}
