import { useEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";

type Saga = { id: string; status: string; step: string };
type Status = { available: boolean; sagas?: Saga[] };

/// Read-only, on-demand projection. It never resumes, abandons or mutates a saga.
export function FleetSagaPill({ readStatus }: { readStatus: () => Promise<unknown> }) {
  const t = useT();
  const label = t("header.fleetSagas");
  const [open, setOpen] = useState(false);
  const [refresh, setRefresh] = useState(0);
  const [status, setStatus] = useState<Status>();
  useEffect(() => {
    if (!open) return;
    let disposed = false;
    setStatus(undefined);
    void readStatus()
      .then((raw) => {
        if (disposed) return;
        const value = raw as Status | undefined;
        setStatus(value?.available === true && Array.isArray(value.sagas) ? value : { available: false });
      })
      .catch(() => {
        if (!disposed) setStatus({ available: false });
      });
    return () => {
      disposed = true;
    };
  }, [open, refresh, readStatus]);
  const [button, setButton] = useState<HTMLButtonElement | null>(null);
  const buttonRef = useRef<HTMLButtonElement | null>(null);
  const trigger = usePopoverTrigger(open, setOpen);
  return (
    <>
      <button
        ref={(element) => {
          buttonRef.current = element;
          setButton(element);
        }}
        type="button"
        className="acpmux-header-tool acpmux-header-live-tree"
        aria-label={label}
        {...trigger}
      >
        <Icon name="list.bullet" size={14} />
        <span>{label}</span>
      </button>
      <Popover
        id={trigger["aria-controls"]}
        open={open}
        onOpenChange={(next) => {
          if (!next) setOpen(false);
        }}
        anchor={button}
        label={label}
        className="acpmux-pr-status acpmux-live-tree-status"
        side="bottom"
        finalFocus={buttonRef}
      >
        <div className="acpmux-pr-title">{label}</div>
        <div className="acpmux-pr-facts">{t("header.fleetSagasSummary")}</div>
        <output className="acpmux-pr-facts">
          {!status
            ? "…"
            : !status.available
              ? t("header.fleetSagasUnavailable")
              : status.sagas?.length
                ? t("header.fleetSagasOpen")
                : t("header.fleetSagasNone")}
        </output>
        {status?.available && status.sagas && (
          <ul className="acpmux-live-tree-results">
            {status.sagas.map((saga) => (
              <li key={saga.id}>
                <code>{saga.id}</code>
                <span>{t("header.fleetSagasStatusAt", { status: saga.status, step: saga.step })}</span>
              </li>
            ))}
          </ul>
        )}
        <button
          type="button"
          className="acpmux-header-tool acpmux-header-live-tree"
          disabled={!status}
          onClick={() => setRefresh((value) => value + 1)}
        >
          {t("git.refresh")}
        </button>
      </Popover>
    </>
  );
}
