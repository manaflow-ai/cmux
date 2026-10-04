// The create sheet: name, memory (the plan's `memory_options_mb`; sizes in
// `locked_memory_options_mb` show disabled with the reason), source (base image or one of the team's
// snapshots, sent as `from_snapshot`) and the plan's active machine limit as the backend reports it.
// The page never computes a limit: a refusal (`plan_required`, `quota_exceeded`, `size_locked`)
// shows as a sentence with "See plans". Create is a money op, so the host confirms it natively. The
// draft holds one idempotency key, so a double submit or a retry creates one machine. Plain Return
// submits and Escape closes; chords are ignored.
import type { KeyboardEvent } from "react";
import type { Strings } from "../shared/i18n";
import { formatMegabytes, memoryChoices, plain } from "./model";
import { PlanNotice } from "./Notices";
import type { CloudState, CloudStore, CreateDraft } from "./store";
import { format, L } from "./strings";

const focusOnMount = (node: HTMLInputElement | null) => node?.focus();

export function CreateSheet({
  store,
  state,
  draft,
  strings,
}: {
  store: CloudStore;
  state: CloudState;
  draft: CreateDraft;
  strings: Strings;
}) {
  const { t, language } = strings;
  const plan = state.plan;
  const choices = memoryChoices(plan);
  // A size is required; without a plan there is no size to offer.
  const canSubmit = !draft.submitting && draft.memoryMb !== undefined;
  const reached = !!plan && plan.usage.active >= plan.limits.max_active;
  // Each field takes plain Escape (close) and, for inputs, plain Return (create).
  const onKeyDown = (event: KeyboardEvent<HTMLInputElement | HTMLSelectElement>) => {
    if (!plain(event)) return;
    if (event.key === "Escape") store.closeCreate();
    else if (event.key === "Enter" && event.currentTarget.tagName === "INPUT") void store.submitCreate();
    else return;
    event.preventDefault();
    event.stopPropagation();
  };
  return (
    <div className="cloud-sheet-backdrop">
      <dialog open className="cloud-create-sheet" aria-modal="true" aria-labelledby="cloud-create-title">
        <h2 id="cloud-create-title" className="cloud-sheet-title">
          {t(L.createSheetTitle)}
        </h2>
        <label className="cloud-field">
          <span className="cloud-field-label">{t(L.createName)}</span>
          <input
            className="cloud-input cloud-create-name"
            type="text"
            value={draft.name}
            maxLength={80}
            placeholder={t(L.createNamePlaceholder)}
            disabled={draft.submitting}
            aria-label={t(L.createName)}
            ref={focusOnMount}
            onKeyDown={onKeyDown}
            onChange={(event) => store.updateDraft({ name: event.target.value })}
          />
        </label>
        {choices.length > 0 && (
          <fieldset className="cloud-field cloud-size-choices" disabled={draft.submitting}>
            <legend className="cloud-field-label">{t(L.createSize)}</legend>
            {choices.map(({ mb, allowed }) => (
              <label key={mb} className={`cloud-size-choice${allowed ? "" : " unavailable"}`}>
                <input
                  type="radio"
                  name="cloud-size"
                  value={mb}
                  checked={draft.memoryMb === mb}
                  disabled={!allowed}
                  aria-label={formatMegabytes(mb, t, language)}
                  onKeyDown={onKeyDown}
                  onChange={() => store.updateDraft({ memoryMb: mb })}
                />
                <span className="cloud-size-name">{formatMegabytes(mb, t, language)}</span>
                {!allowed && <span className="cloud-badge cloud-size-locked">{t(L.sizeNotInPlan)}</span>}
              </label>
            ))}
          </fieldset>
        )}
        <label className="cloud-field">
          <span className="cloud-field-label">{t(L.createSnapshot)}</span>
          <select
            className="cloud-input cloud-create-snapshot"
            value={draft.from_snapshot ?? ""}
            disabled={draft.submitting}
            onKeyDown={onKeyDown}
            onChange={(event) => store.updateDraft({ from_snapshot: event.target.value || undefined })}
          >
            <option value="">{t(L.createBaseImage)}</option>
            {draft.snapshots?.map((snapshot) => (
              <option key={snapshot.id} value={snapshot.id}>
                {snapshot.name || snapshot.id}
              </option>
            ))}
          </select>
        </label>
        {plan && (
          <p className={`cloud-plan-limit${reached ? " reached" : ""}`}>
            {format(t(reached ? L.createLimitReached : L.createLimit), {
              used: plan.usage.active,
              limit: plan.limits.max_active,
              plan: plan.plan_id,
            })}
          </p>
        )}
        {draft.refusal && <PlanNotice store={store} refusal={draft.refusal} strings={strings} />}
        {draft.blocked === "no_snapshot_configured" && (
          <p className="cloud-sheet-error cloud-create-blocked" role="alert">
            {t(L.noSnapshotConfigured)}
          </p>
        )}
        {draft.error && (
          <p className="cloud-sheet-error" role="alert">
            {t(L.actionFailed)} <span className="cloud-error-detail">{draft.error}</span>
          </p>
        )}
        <div className="cloud-sheet-actions">
          <button
            type="button"
            className="cloud-button"
            disabled={draft.submitting}
            onClick={() => store.closeCreate()}
          >
            {t(L.cancel)}
          </button>
          <button
            type="button"
            className="cloud-button primary cloud-create-submit"
            aria-disabled={!canSubmit}
            onClick={() => canSubmit && void store.submitCreate()}
          >
            {t(draft.submitting ? L.createSubmitting : L.createSubmit)}
          </button>
        </div>
      </dialog>
    </div>
  );
}
