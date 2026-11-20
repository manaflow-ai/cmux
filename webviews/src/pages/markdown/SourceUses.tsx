import { useEffect, useId, useMemo, useState, useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { L } from "./strings";
import { SourceUses as SourceUsesModel, type SourceUsesClient } from "./sourceUses";
import "./SourceUses.css";

/** Mounted only while the host grants a source-use context for the current file. */
export function SourceUses({ path, client, strings }: { path: string; client: SourceUsesClient; strings: Strings }) {
  const model = useMemo(() => new SourceUsesModel(client, path), [client, path]);
  const state = useSyncExternalStore(model.subscribe, model.getState);
  const [open, setOpen] = useState(false);
  const id = useId();
  const dates = useMemo(
    () =>
      new Intl.DateTimeFormat(strings.language, {
        dateStyle: "medium",
        timeStyle: "short",
      }),
    [strings.language],
  );
  useEffect(() => {
    model.setDocument(path);
    return () => model.dispose();
  }, [model, path]);
  const { t } = strings;
  return (
    <section className="md-source-uses">
      <button
        type="button"
        className="md-source-uses__toggle"
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        onClick={() => {
          setOpen(!open);
          if (!open && !state.loaded) void model.load();
        }}
      >
        <span aria-hidden="true" className="md-source-uses__chevron" data-open={open} />
        {t(L.sourceUses)}
      </button>
      {open && (
        <div id={id} aria-busy={state.loading}>
          <ul className="md-source-uses__list">
            {state.uses.map((use) => (
              <li key={`${use.seq}:${use.replyId}:${use.toolCallId}`}>
                <button
                  type="button"
                  className="md-source-uses__reply"
                  disabled={state.revealing}
                  onClick={() => void model.reveal(use)}
                >
                  {t(L.sourceUsesReply)}
                  <time dateTime={new Date(use.at).toISOString()}>{dates.format(use.at)}</time>
                </button>
              </li>
            ))}
          </ul>
          {state.loading && <p role="status">{t(L.loading)}</p>}
          {state.error && <p role="alert">{t(L.sourceUsesFailed)}</p>}
          {state.revealError && <p role="alert">{t(L.sourceUsesRevealFailed)}</p>}
          {state.capped && <p>{t(L.sourceUsesLimit)}</p>}
          {state.loaded && !state.loading && !state.error && state.uses.length === 0 && state.nextCursor === null && (
            <p>{t(L.sourceUsesEmpty)}</p>
          )}
          {!state.loading && (state.error || state.nextCursor !== null) && (
            <button type="button" className="md-source-uses__more" onClick={() => void model.load()}>
              {t(state.error ? L.retry : L.sourceUsesMore)}
            </button>
          )}
        </div>
      )}
    </section>
  );
}
