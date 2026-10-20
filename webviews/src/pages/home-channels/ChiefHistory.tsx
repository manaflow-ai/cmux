// A Chief's history in its editor (ChiefPage.tsx): every committed state of the record
// (`chief.profile.history`), newest first, each with when, who (you, or the Chief that made it)
// and what changed. Undo Last Change makes the record equal to the revision before the current
// one; Restore This Version to that revision (`chief.profile.undo`, a new revision either way).
import { useEffect, useMemo, useState } from "react";
import type { Strings } from "../shared/i18n";
import { revisionChanges, type ChiefEditorService } from "./chiefEditing";
import type { HomeChief, HomeChiefRevision } from "./types";

export function ChiefHistory({
  service,
  strings,
  chief,
  disabled,
  chiefName,
  onUndo,
}: {
  service: ChiefEditorService;
  strings: Strings;
  chief: HomeChief;
  disabled: boolean;
  chiefName(id: string): string | undefined;
  /** Undo (no revision) or Restore (`toRev`). */
  onUndo(toRev?: number): void;
}) {
  const { t } = strings;
  const [revisions, setRevisions] = useState<HomeChiefRevision[] | undefined>();
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let live = true;
    service.history(chief.id).then(
      (list) => {
        if (live) setRevisions(list);
      },
      () => {
        if (!live) return;
        setRevisions([]);
        setFailed(true);
      },
    );
    return () => {
      live = false;
    };
  }, [service, chief.id]);
  const stamp = useMemo(
    () => new Intl.DateTimeFormat(strings.language, { dateStyle: "medium", timeStyle: "short" }),
    [strings.language],
  );
  const list = revisions ?? [];
  const when = (at: string) => {
    const date = new Date(at);
    return Number.isNaN(date.getTime()) ? at : stamp.format(date);
  };
  return (
    <section className="ce-field ce-history" aria-label={t("chief.history.title")} data-chief-history="">
      <span className="ce-row">
        <span className="ce-label ce-grow">{t("chief.history.title")}</span>
        <button
          type="button"
          className="ce-button"
          disabled={disabled || list.length < 2}
          onClick={() => onUndo(undefined)}
        >
          {t("chief.history.undo")}
        </button>
      </span>
      {revisions === undefined ? (
        <span className="ce-note">{t("chief.history.loading")}</span>
      ) : failed ? (
        <span className="ce-note">{t("chief.history.unavailable")}</span>
      ) : list.length === 0 ? (
        <span className="ce-note">{t("chief.history.empty")}</span>
      ) : (
        <ol className="ce-history-list">
          {list.map((revision, index) => {
            const previous = list[index + 1]?.record;
            const changes = revisionChanges(revision.record, previous);
            const who = revision.actor ? (chiefName(revision.actor) ?? revision.actor) : t("chief.history.you");
            const what = previous
              ? changes.map((field) => t(`chief.change.${field}`)).join(", ")
              : t("chief.history.created");
            return (
              <li key={revision.rev} className="ce-history-row" data-rev={revision.rev}>
                <span className="ce-history-text">
                  <span className="ce-history-what">{what}</span>
                  <span className="ce-note">
                    <time dateTime={revision.at}>{when(revision.at)}</time>
                    {" · "}
                    <span className="ce-history-who">{who}</span>
                  </span>
                </span>
                {index === 0 ? (
                  <span className="ce-note">{t("chief.history.current")}</span>
                ) : (
                  <button
                    type="button"
                    className="ce-button"
                    disabled={disabled}
                    onClick={() => onUndo(revision.rev)}
                  >
                    {t("chief.history.restore")}
                  </button>
                )}
              </li>
            );
          })}
        </ol>
      )}
    </section>
  );
}
