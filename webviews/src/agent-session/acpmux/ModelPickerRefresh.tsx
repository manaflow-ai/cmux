import { useEffect, useRef, useState } from "react";
import { CheckIcon } from "./ComposerPickers";
import { currentLanguage, useT } from "./i18n";
import { Icon } from "./icons/Icon";
import type { CatalogRefreshState } from "./modelPickerLayout";

/** Catalog transport stays with the host; the footer makes its work visible in the picker. */
export function ModelPickerRefresh({ state }: { state: CatalogRefreshState }) {
  const t = useT();
  const [local, setLocal] = useState<{ status: "fetching" | "updated" | "error"; date?: string }>();
  const request = useRef(0);
  useEffect(() => {
    // Host events outrank a pending local promise, including an error arriving before it settles.
    request.current += 1;
    setLocal(undefined);
  }, [state.status, state.date]);
  useEffect(
    () => () => {
      request.current += 1;
    },
    [],
  );
  const status = local?.status ?? state.status ?? "idle";
  const date = local?.date ?? state.date;
  const timestamp = date ? new Date(date) : undefined;
  const formatted =
    timestamp && Number.isFinite(timestamp.getTime())
      ? new Intl.DateTimeFormat(currentLanguage(), { dateStyle: "medium", timeStyle: "short" }).format(timestamp)
      : undefined;
  const message =
    status === "fetching"
      ? t("picker.catalogRefreshing")
      : status === "error"
        ? t("picker.catalogRefreshError")
        : status === "updated"
          ? t("picker.catalogCurrent")
          : t("picker.catalogReady");
  const refresh = () => {
    if (status === "fetching") return;
    const id = ++request.current;
    setLocal({ status: "fetching" });
    try {
      Promise.resolve(state.refresh()).then(
        () => {
          if (request.current === id) setLocal({ status: "updated", date: new Date().toISOString() });
        },
        () => {
          if (request.current === id) setLocal({ status: "error" });
        },
      );
    } catch {
      if (request.current === id) setLocal({ status: "error" });
    }
  };
  return (
    <div
      className="relative flex flex-none flex-col gap-2 border-t-[0.5px] border-edge bg-menu px-3 py-3"
      data-refresh-status={status}
    >
      <div role="status" aria-live="polite" className="min-w-0 text-detail text-muted">
        <div className="flex items-center gap-1.5 text-fg">
          {status === "updated" && <CheckIcon />}
          {status === "error" && (
            <span
              aria-hidden="true"
              className="grid size-4 place-items-center rounded-full border border-solid border-edge font-semibold"
            >
              !
            </span>
          )}
          <span>{message}</span>
        </div>
        {formatted && (
          <div className="mt-1 text-caption text-dim">{t("picker.catalogUpdated", { date: formatted })}</div>
        )}
      </div>
      <button
        type="button"
        className="flex min-h-8 w-full cursor-pointer items-center justify-center gap-2 rounded-lg border border-solid border-edge bg-hover px-2 py-1 font-[inherit] text-detail text-fg hover:border-muted disabled:cursor-default"
        aria-label={t("picker.refreshCatalog")}
        disabled={status === "fetching"}
        onClick={refresh}
      >
        {status === "fetching" ? (
          <span className="acpmux-mp-refresh-spinner" aria-hidden="true" />
        ) : (
          <Icon name="action.reload" size={13} />
        )}
        <span>{status === "error" ? t("picker.tryAgain") : t("picker.refreshCatalog")}</span>
      </button>
      {status === "fetching" && (
        <div aria-hidden="true" className="absolute inset-x-0 top-0 h-0.5 overflow-hidden bg-hover">
          <div className="h-full w-1/3 bg-muted motion-safe:animate-pulse" />
        </div>
      )}
    </div>
  );
}
