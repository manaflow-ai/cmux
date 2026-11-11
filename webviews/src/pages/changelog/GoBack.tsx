// Going back to an earlier build from the Updated card's changes (the hover card beside the
// sidebar). Leo 2026-11-11 asked for a faster, more reliable way back to the previous nightly, and
// a better UI for it. One clear entry, "Go back to nightly 4288034 from Nov 10", under the changes;
// "Other builds" opens the last few builds, each with its date and first change, and Go back on
// the ones this Mac can take. The progress itself shows on the sidebar's notice card (native), which
// names the step; this footer only says it started, or why it did not.
//
// Looks (gallery variants, `footer` ships): `footer`, the entry at the foot of the list with the
// builds behind a disclosure; `header`, a quiet link on the header's line beside What's New; `list`,
// the builds always open with the previous one marked.
import { useEffect, useState } from "react";
import type { Strings } from "../shared/i18n";
import type { RecentBuildRow, UpdateGoBack, UpdateSurfaceActions } from "./updateHighlights";
import { cardVersion } from "./UpdateSurfaces";

export type GoBackLook = "footer" | "header" | "list";

/** "Nov 10" from `YYYY-MM-DD`, in the page's language; the text as given when it is not a date. */
export function buildDay(date: string, language: string): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  if (!match) return date;
  const day = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]), 12));
  return new Intl.DateTimeFormat(language, { month: "short", day: "numeric", timeZone: "UTC" }).format(day);
}

type State = { kind: "idle" } | { kind: "going"; build?: string } | { kind: "failed"; message: string };

/** The way back: one entry, and the recent builds behind it. Nothing when the host offers neither. */
export function GoBack({
  goBack,
  strings,
  actions,
  look = "footer",
  builds: fixedBuilds,
  open: fixedOpen,
  state: fixedState,
}: {
  goBack?: UpdateGoBack | null;
  strings: Strings;
  actions: UpdateSurfaceActions;
  look?: GoBackLook;
  /** The list as given (gallery); undefined asks the host when it opens. */
  builds?: RecentBuildRow[];
  /** Holds the list open (gallery stills). */
  open?: boolean;
  /** Holds a state (gallery stills). */
  state?: State;
}) {
  const [open, setOpen] = useState(look === "list");
  const [builds, setBuilds] = useState<RecentBuildRow[] | null>(fixedBuilds ?? null);
  const [state, setState] = useState<State>({ kind: "idle" });
  const shown = fixedOpen ?? open;
  const now = fixedState ?? state;
  useEffect(() => {
    if (!shown || builds || fixedBuilds || !actions.builds) return;
    let live = true;
    void actions.builds().then((rows) => live && setBuilds(rows), () => live && setBuilds([]));
    return () => {
      live = false;
    };
  }, [shown, builds, fixedBuilds, actions]);
  if (!actions.goBack || (!goBack && !actions.builds)) return null;
  const go = (build?: string) => {
    setState({ kind: "going", build });
    void actions.goBack!(build).then(
      (failure) => setState(failure ? { kind: "failed", message: failure } : { kind: "going", build }),
      () => setState({ kind: "failed", message: strings.t("updates.goBack.failed") }),
    );
  };
  const busy = now.kind === "going";
  const entry = goBack ? (
    <button
      type="button"
      className="wn-goback-entry"
      disabled={busy}
      onClick={() => go()}
      title={goBack.kept ? strings.t("updates.goBack.keptHelp") : strings.t("updates.goBack.downloadHelp")}
    >
      <svg className="wn-goback-glyph" viewBox="0 0 12 12" width="12" height="12" aria-hidden="true">
        <path d="M4.5 3 2 5.5 4.5 8M2.4 5.5h4.6a3 3 0 0 1 0 6H6" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
      <span className="wn-goback-label">
        {busy && now.build === undefined ? strings.t("updates.goBack.going") : goBack.title}
      </span>
    </button>
  ) : null;
  const disclosure = look !== "list" && actions.builds && (
    <button
      type="button"
      className="wn-goback-more"
      aria-expanded={shown}
      onClick={() => setOpen(!shown)}
    >
      {strings.t("updates.goBack.otherBuilds")}
      <svg viewBox="0 0 12 12" width="10" height="10" aria-hidden="true" data-open={shown ? "" : undefined}>
        <path d="M3 4.5 6 7.5 9 4.5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
      </svg>
    </button>
  );
  return (
    <section className="wn-goback" data-look={look} aria-label={strings.t("updates.goBack.section")}>
      {look === "header" ? null : <div className="wn-goback-row">{entry}{disclosure}</div>}
      {now.kind === "failed" && (
        <p className="wn-goback-failure" role="alert">
          {now.message}
        </p>
      )}
      {shown && (
        <ul className="wn-goback-builds" aria-label={strings.t("updates.goBack.otherBuilds")}>
          {builds === null && <li className="wn-goback-loading">{strings.t("updates.goBack.loading")}</li>}
          {builds?.map((row) => (
            <BuildRow
              key={row.build}
              row={row}
              previous={row.build === goBack?.build}
              strings={strings}
              busy={busy}
              going={busy && now.build === row.build}
              onGo={() => go(row.build)}
            />
          ))}
        </ul>
      )}
    </section>
  );
}

/** The header look's entry: a quiet link on the title's line, beside What's New. */
export function GoBackHeaderLink({
  goBack,
  strings,
  actions,
}: {
  goBack?: UpdateGoBack | null;
  strings: Strings;
  actions: UpdateSurfaceActions;
}) {
  if (!goBack || !actions.goBack) return null;
  return (
    <button type="button" className="wn-notes-whatsnew wn-goback-headlink" onClick={() => void actions.goBack!()} title={goBack.title}>
      {strings.t("updates.goBack.short")}
    </button>
  );
}

function BuildRow({
  row,
  previous,
  strings,
  busy,
  going,
  onGo,
}: {
  row: RecentBuildRow;
  previous: boolean;
  strings: Strings;
  busy: boolean;
  going: boolean;
  onGo: () => void;
}) {
  const tag = row.installed
    ? strings.t("updates.goBack.running")
    : row.pulled
      ? strings.t("updates.goBack.pulled")
      : row.kept
        ? strings.t("updates.goBack.kept")
        : null;
  return (
    <li className="wn-goback-build" data-installed={row.installed ? "" : undefined} data-previous={previous ? "" : undefined}>
      <div className="wn-goback-build-head">
        <span className="wn-goback-build-name">{cardVersion(row.version)}</span>
        <span className="wn-goback-build-date">{buildDay(row.date, strings.language)}</span>
        {tag && <span className="wn-goback-build-tag">{tag}</span>}
        {row.switchable && !row.installed && (
          <button type="button" className="wn-goback-build-go" disabled={busy} onClick={onGo}>
            {going ? strings.t("updates.goBack.going") : strings.t("updates.goBack.button")}
          </button>
        )}
      </div>
      {row.titles.length > 0 && <div className="wn-goback-build-change">{row.titles[0]}</div>}
    </li>
  );
}
