// The Review tab, shown only to a registry reviewer (`cmux.registry.me` says `reviewer`;
// custom-panes-DESIGN.md 6.4): the pending queue, and for the selected submission its manifest
// summary, notes, file list, a file viewer to read the code, and Approve or Reject with a reason.
// An approve shows the Mac's native sheet first; a reject needs 8 to 500 characters.
import { useState } from "react";
import type { Strings } from "../shared/i18n";
import { DetailSection } from "./items";
import { AppIcon, Badge } from "./parts";
import { NO_REGISTRY, type AppsSnapshot, type AppsStore } from "./store";
import { formatWhen } from "./Submissions";
import { REJECT_REASON, type ReviewSubmission } from "./types";
import { manifestSummary } from "./wire";

export function ReviewView({ snap, store, strings }: { snap: AppsSnapshot; store: AppsStore; strings: Strings }) {
  const { t } = strings;
  const registry = snap.registry ?? NO_REGISTRY;
  const selected = registry.queue.find((item) => item.id === registry.reviewSelection);
  const list =
    registry.queueStatus === "error" ? (
      <p className="apps-muted apps-review-note" role="alert">
        <strong>{t("store.error.load")}</strong> <span className="selectable">{registry.queueError}</span>
      </p>
    ) : registry.queue.length === 0 ? (
      <p className="apps-muted apps-review-note">
        {registry.queueStatus === "loading" ? t("store.detail.loading") : t("store.registry.queueEmpty")}
      </p>
    ) : (
      <ul className="apps-rows apps-review-queue">
        {registry.queue.map((item) => {
          const summary = manifestSummary(item.manifest);
          const name = summary.name ?? item.app;
          return (
            <li
              key={item.id}
              className={`apps-row${item.id === selected?.id ? " selected" : ""}`}
              data-submission={item.id}
            >
              <button
                type="button"
                className="apps-row-open"
                aria-current={item.id === selected?.id}
                onClick={() => store.selectReview(item.id)}
              >
                <AppIcon icon={summary.symbol ? { symbol: summary.symbol } : undefined} name={name} size={28} />
                <span className="apps-row-text">
                  <span className="apps-name">{name}</span>
                  <span className="apps-muted">
                    {item.app} <span className="apps-version">{item.version}</span>
                  </span>
                  <span className="apps-muted">{item.submitter.user}</span>
                </span>
              </button>
            </li>
          );
        })}
      </ul>
    );
  return (
    <div className="apps-split apps-review">
      <div className="apps-split-list apps-review-list">{list}</div>
      <div className="apps-split-detail">
        {selected ? (
          <ReviewDetail key={selected.id} item={selected} snap={snap} store={store} strings={strings} />
        ) : (
          <div className="apps-empty">{t("store.registry.selectSubmission")}</div>
        )}
      </div>
    </div>
  );
}

function ReviewDetail({
  item,
  snap,
  store,
  strings,
}: {
  item: ReviewSubmission;
  snap: AppsSnapshot;
  store: AppsStore;
  strings: Strings;
}) {
  const { t, format } = strings;
  const registry = snap.registry ?? NO_REGISTRY;
  const [reason, setReason] = useState("");
  const summary = manifestSummary(item.manifest);
  const name = summary.name ?? item.app;
  const open = registry.reviewFile?.id === item.id ? registry.reviewFile : undefined;
  const busy = registry.busy !== undefined;
  const submitter = item.submitter.email ? `${item.submitter.user} (${item.submitter.email})` : item.submitter.user;
  return (
    <div className="apps-detail" data-review={item.id}>
      <div className="apps-detail-body">
        <header className="apps-detail-header">
          <AppIcon icon={summary.symbol ? { symbol: summary.symbol } : undefined} name={name} size={64} />
          <div className="apps-detail-title">
            <h1 className="apps-detail-name">{name}</h1>
            <div className="apps-detail-meta">
              <span className="selectable">{item.app}</span>
              <span className="apps-version">{format("store.updates.version", summary.version ?? item.version)}</span>
              <Badge text={t("store.registry.status.pending")} />
            </div>
            <span className="apps-muted selectable">
              {format("store.registry.submitter", submitter)} ·{" "}
              {format("store.registry.submitted", formatWhen(item.submitted_at, strings.language))}
            </span>
          </div>
        </header>
        {summary.description && <p className="apps-detail-description selectable">{summary.description}</p>}
        {item.notes ? (
          <DetailSection title={t("store.registry.notesTitle")}>
            <p className="apps-review-notes selectable">{item.notes}</p>
          </DetailSection>
        ) : null}
        <DetailSection title={t("store.detail.permissions")}>
          {summary.scopes.length === 0 ? (
            <p className="apps-muted">{t("store.detail.noPermissions")}</p>
          ) : (
            <ul className="apps-scopes">
              {summary.scopes.map((scope) => (
                <li key={`${scope.optional ? "o" : "r"}\u0000${scope.scope}`} className="apps-scope">
                  <code>{scope.scope}</code>
                  {scope.optional && <Badge text={t("store.detail.optional")} />}
                  <span className="apps-muted selectable">{scope.reason}</span>
                </li>
              ))}
            </ul>
          )}
        </DetailSection>
        <DetailSection title={t("store.registry.files")}>
          <ul className="apps-review-files">
            {item.files.map((file) => (
              <li key={file.path}>
                <button
                  type="button"
                  className={`apps-review-file${open?.path === file.path ? " selected" : ""}`}
                  aria-pressed={open?.path === file.path}
                  onClick={() => void store.openReviewFile(item.id, file.path)}
                >
                  <code>{file.path}</code>
                  <span className="apps-muted">{format("store.registry.bytes", String(file.size))}</span>
                </button>
              </li>
            ))}
          </ul>
          {open && (
            <div className="apps-review-viewer" data-file-state={open.status}>
              {open.status === "loading" ? (
                <p className="apps-muted">{t("store.detail.loading")}</p>
              ) : open.status === "error" ? (
                <p className="apps-muted" role="alert">
                  <strong>{t("store.error.load")}</strong> <span className="selectable">{open.error}</span>
                </p>
              ) : open.file?.kind === "text" ? (
                <pre className="apps-logs apps-review-code selectable" aria-label={open.path}>
                  {open.file.text}
                </pre>
              ) : (
                <p className="apps-muted">{format("store.registry.binary", String(open.file?.size ?? 0))}</p>
              )}
            </div>
          )}
        </DetailSection>
        <DetailSection title={t("store.registry.decision")}>
          <div className="apps-submit">
            <label className="apps-field">
              <span>{t("store.registry.rejectReason")}</span>
              <textarea
                className="apps-field-input"
                name="reason"
                aria-label={t("store.registry.rejectReason")}
                rows={3}
                maxLength={REJECT_REASON.max}
                value={reason}
                aria-invalid={registry.reviewFormError ? true : undefined}
                onChange={(event) => setReason(event.target.value)}
              />
            </label>
            {registry.reviewFormError && (
              <p className="apps-failure apps-review-form-error" role="alert">
                {t(registry.reviewFormError)}
              </p>
            )}
            <div className="apps-submit-actions">
              <button
                type="button"
                className="apps-button"
                disabled={busy}
                onClick={() => void store.decide(item.id, "reject", reason)}
              >
                {t("store.registry.reject")}
              </button>
              <button
                type="button"
                className="apps-button primary"
                disabled={busy}
                onClick={() => void store.decide(item.id, "approve", reason)}
              >
                {t("store.registry.approve")}
              </button>
            </div>
          </div>
        </DetailSection>
      </div>
    </div>
  );
}
