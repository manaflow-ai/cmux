// Settings > Chief > Diagnostics: the page's last card, one glass card. A row for the Chief (running
// when the host's relay lists Chiefs, as the Chiefs card reads it), then every backend acpmux offers
// a Chief (`cmux.chief.backend.list`), each with Check: the same real hello turn the Chief editor
// runs before it saves a new backend (`cmux.chief.backend.doctor`). The answer stays in the row: that
// it answered, or the step that failed with its detail and fix. Nothing here changes a setting.
import { useCallback, useEffect, useMemo, useState } from "react";
import { ChiefHost } from "../../home-channels/chiefEditing";
import type { HomeChiefBackend, HomeChiefDoctor } from "../../home-channels/types";
import { formatString } from "../../shared/i18n";
import { useStore } from "../context";
import { t } from "../strings";

type Check = { state: "checking" } | { state: "passed" } | { state: "failed"; step?: HomeChiefDoctor["steps"][number] };

const format = (key: string, ...args: string[]) => formatString(t(key), args);

export function ChiefDiagnosticsCard() {
  const store = useStore();
  const host = useMemo(() => new ChiefHost(store.chiefCalls), [store]);
  // Whether the Chief answers (`undefined` until the host says), and the backends acpmux lists.
  const [running, setRunning] = useState<boolean | undefined>();
  const [backends, setBackends] = useState<HomeChiefBackend[] | undefined>();
  const [checks, setChecks] = useState<ReadonlyMap<string, Check>>(new Map());
  useEffect(() => {
    let live = true;
    host.rawList().then(
      () => live && setRunning(true),
      () => live && setRunning(false),
    );
    host.backends().then(
      (list) => live && setBackends(list),
      () => live && setBackends([]),
    );
    return () => {
      live = false;
    };
  }, [host]);
  const settle = useCallback((id: string, check: Check) => setChecks((now) => new Map(now).set(id, check)), []);
  const run = useCallback(
    (id: string) => {
      settle(id, { state: "checking" });
      host.checkBackend(id).then(
        (result) =>
          settle(
            id,
            result.ok ? { state: "passed" } : { state: "failed", step: result.steps.find((step) => !step.ok) },
          ),
        (error: unknown) =>
          settle(id, {
            state: "failed",
            step: { name: "doctor", ok: false, detail: error instanceof Error ? error.message : String(error) },
          }),
      );
    },
    [host, settle],
  );
  return (
    <section className="group chief-diagnostics ui-glass" data-card="chief-diagnostics">
      <h3 className="group-title">{t("chief.diagnostics.title")}</h3>
      <p className="row-help" data-intro="">
        {t("chief.diagnostics.intro")}
      </p>
      <div className="rows">
        <div className="row chief-diagnostic" data-diagnostic="chief">
          <div className="row-main">
            <div className="row-label">
              <div className="row-title">{t("chief.diagnostics.chief")}</div>
              {running === false && <div className="row-help">{t("chief.settings.unavailable")}</div>}
            </div>
            {running !== undefined && (
              <span className="row-help chief-diagnostic-status" data-ok={running ? "true" : "false"}>
                {t(running ? "chief.diagnostics.running" : "chief.diagnostics.notRunning")}
              </span>
            )}
          </div>
        </div>
        {backends?.length === 0 && (
          <div className="row chief-diagnostic" data-diagnostic="">
            <div className="row-help">{t("chief.diagnostics.noBackends")}</div>
          </div>
        )}
        {backends?.map((backend) => (
          <BackendRow
            key={backend.id}
            backend={backend}
            check={checks.get(backend.id)}
            disabled={running !== true}
            onCheck={() => run(backend.id)}
          />
        ))}
      </div>
    </section>
  );
}

function BackendRow({
  backend,
  check,
  disabled,
  onCheck,
}: {
  backend: HomeChiefBackend;
  check: Check | undefined;
  disabled: boolean;
  onCheck(): void;
}) {
  // The row's word: the check's answer once there is one, else whether acpmux can run it (its reason
  // when it cannot).
  const status = !check
    ? (backend.unavailable ?? t("chief.diagnostics.ready"))
    : check.state === "checking"
      ? t("chief.backend.checking")
      : check.state === "passed"
        ? t("chief.backend.passed")
        : format("chief.backend.failed", check.step?.name ?? "doctor");
  const ok = check ? check.state === "passed" : !backend.unavailable;
  const failed = check?.state === "failed" ? check.step : undefined;
  return (
    <div className="row chief-diagnostic" data-diagnostic={backend.id}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title">{backend.name}</div>
          {failed?.detail && <div className="row-help">{failed.detail}</div>}
          {failed?.fix && <div className="row-help">{format("chief.backend.fix", failed.fix)}</div>}
        </div>
        <span
          className="row-help chief-diagnostic-status"
          data-ok={check?.state === "checking" ? undefined : String(ok)}
        >
          {status}
        </span>
        <button type="button" className="button" disabled={disabled || check?.state === "checking"} onClick={onCheck}>
          {t(check ? "chief.backend.recheck" : "chief.diagnostics.check")}
        </button>
      </div>
    </div>
  );
}
