// Publishing from the Installed tab (custom-panes-DESIGN.md 6.4): Submit for Review on an installed
// `local/` app and My Submissions with each one's status and the reviewer's reason. The Mac shows
// a native confirmation before it sends a submission; a declined sheet leaves the form as it was.
import { useState } from "react";
import type { Strings } from "../shared/i18n";
import { Badge } from "./parts";
import { NO_REGISTRY, type AppsSnapshot, type AppsStore } from "./store";
import type { RegistrySubmission, SubmissionStatus } from "./types";

const STATUS_LABEL: Record<SubmissionStatus, string> = {
  pending: "store.registry.status.pending",
  approved: "store.registry.status.approved",
  rejected: "store.registry.status.rejected",
};

/** A registry time (ISO text or epoch milliseconds) as a short date in the page's language. */
export function formatWhen(value: string | number | null | undefined, language: string): string {
  if (value === null || value === undefined || value === "") return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  try {
    return date.toLocaleDateString(language, { year: "numeric", month: "short", day: "numeric" });
  } catch {
    return date.toISOString().slice(0, 10);
  }
}

/**
 * The Submit for Review form of an installed local app: the publisher (prefilled with the person's
 * first publisher from `cmux.registry.me`) and optional notes. Signed out, only the hint shows.
 */
export function SubmitForm({
  app,
  snap,
  store,
  strings,
}: {
  app: string;
  snap: AppsSnapshot;
  store: AppsStore;
  strings: Strings;
}) {
  const { t } = strings;
  const registry = snap.registry ?? NO_REGISTRY;
  const me = registry.me;
  // Untouched, the field follows `me` (it can answer after the form opens); typing takes over.
  const [typed, setPublisher] = useState<string | undefined>(undefined);
  const publisher = typed ?? me?.publishers?.[0] ?? "";
  const [notes, setNotes] = useState("");
  if (!me?.signedIn) {
    return <p className="apps-muted apps-submit-hint">{t("store.registry.signedOut")}</p>;
  }
  const busy = registry.busy === app;
  return (
    <form
      className="apps-submit"
      onSubmit={(event) => {
        event.preventDefault();
        if (publisher.trim()) void store.submit(app, publisher, notes);
      }}
    >
      <label className="apps-field">
        <span>{t("store.registry.publisher")}</span>
        <input
          className="apps-field-input"
          name="publisher"
          aria-label={t("store.registry.publisher")}
          value={publisher}
          list={me.publishers?.length ? `apps-publishers-${app}` : undefined}
          autoComplete="off"
          spellCheck={false}
          onChange={(event) => setPublisher(event.target.value)}
        />
        {me.publishers?.length ? (
          <datalist id={`apps-publishers-${app}`}>
            {me.publishers.map((name) => (
              <option key={name} value={name}>
                {name}
              </option>
            ))}
          </datalist>
        ) : null}
      </label>
      <label className="apps-field">
        <span>
          {t("store.registry.notes")} <span className="apps-muted">{t("store.detail.optional")}</span>
        </span>
        <textarea
          className="apps-field-input"
          name="notes"
          aria-label={t("store.registry.notes")}
          rows={3}
          value={notes}
          onChange={(event) => setNotes(event.target.value)}
        />
      </label>
      <div className="apps-submit-actions">
        <button type="button" className="apps-button" onClick={() => store.toggleSubmit(app)}>
          {t("store.registry.cancel")}
        </button>
        <button
          type="submit"
          className="apps-button primary"
          disabled={!publisher.trim() || registry.busy !== undefined}
          aria-busy={busy}
        >
          {t("store.registry.send")}
        </button>
      </div>
    </form>
  );
}

/** My Submissions: every submission the person made, newest first, with the reviewer's reason. */
export function MySubmissions({ snap, strings }: { snap: AppsSnapshot; strings: Strings }) {
  const { t } = strings;
  const registry = snap.registry ?? NO_REGISTRY;
  const status = registry.submissionsStatus;
  // Shown once the person is signed in; nothing for a host without the registry.
  if (status === "idle" || status === "unavailable" || status === "signed-out") return null;
  const rows = [...registry.submissions].sort((a, b) => time(b.submitted_at) - time(a.submitted_at));
  return (
    <section className="apps-installed-row apps-submissions" aria-labelledby="apps-submissions-title">
      <div className="apps-section-heading">
        <h3 id="apps-submissions-title">{t("store.registry.submissions")}</h3>
      </div>
      {status === "error" ? (
        <p className="apps-muted" role="alert">
          <strong>{t("store.error.load")}</strong> <span className="selectable">{registry.submissionsError}</span>
        </p>
      ) : status === "loading" && rows.length === 0 ? (
        <p className="apps-muted">{t("store.detail.loading")}</p>
      ) : rows.length === 0 ? (
        <p className="apps-muted">{t("store.registry.submissionsEmpty")}</p>
      ) : (
        <ul className="apps-submission-list">
          {rows.map((row) => (
            <SubmissionRow key={row.id} row={row} strings={strings} />
          ))}
        </ul>
      )}
    </section>
  );
}

function SubmissionRow({ row, strings }: { row: RegistrySubmission; strings: Strings }) {
  const { t, format } = strings;
  return (
    <li className="apps-submission" data-status={row.status}>
      <span className="apps-submission-line">
        <span className="apps-name">{row.app}</span>
        <span className="apps-version">{row.version}</span>
        <Badge text={t(STATUS_LABEL[row.status] ?? STATUS_LABEL.pending)} />
        <span className="apps-muted">
          {format("store.registry.submitted", formatWhen(row.submitted_at, strings.language))}
        </span>
      </span>
      {row.reason ? (
        <span className="apps-muted selectable apps-submission-reason">
          {format("store.registry.reason", row.reason)}
        </span>
      ) : null}
    </li>
  );
}

function time(value: string | number): number {
  const ms = new Date(value).getTime();
  return Number.isNaN(ms) ? 0 : ms;
}
