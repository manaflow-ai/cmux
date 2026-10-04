// The create sheet: name, memory (the plan's `memoryOptionsMb`; locked sizes are shown but
// disabled), source (base image or a snapshot of the selected machine, which creates through
// `snapshot.restore` and takes no name or size) and the plan's machine limit. The draft holds one
// idempotency key, so a double submit or a retry creates one machine. Plain Return submits and
// Escape closes; chords are ignored.
import type { KeyboardEvent } from "react";
import type { Strings } from "../shared/i18n";
import { activeMachines, atMachineLimit, formatMegabytes, plain } from "./model";
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
  const limited = atMachineLimit(plan, state.machines);
  const used = activeMachines(state.machines);
  const canSubmit = !draft.submitting && !limited;
  const fromSnapshot = !!draft.snapshot_id;
  const memoryChoices = [
    ...(plan?.memoryOptionsMb ?? []).map((mb) => ({ mb, allowed: true })),
    ...(plan?.lockedMemoryOptionsMb ?? []).map((mb) => ({ mb, allowed: false })),
  ];
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
            placeholder={t(L.createNamePlaceholder)}
            disabled={draft.submitting || fromSnapshot}
            aria-label={t(L.createName)}
            ref={focusOnMount}
            onKeyDown={onKeyDown}
            onChange={(event) => store.updateDraft({ name: event.target.value })}
          />
        </label>
        {memoryChoices.length > 0 && (
          <fieldset className="cloud-field cloud-size-choices" disabled={draft.submitting || fromSnapshot}>
            <legend className="cloud-field-label">{t(L.createSize)}</legend>
            {memoryChoices.map(({ mb, allowed }) => (
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
                {!allowed && <span className="cloud-badge">{t(L.sizeNotInPlan)}</span>}
              </label>
            ))}
          </fieldset>
        )}
        <label className="cloud-field">
          <span className="cloud-field-label">{t(L.createSnapshot)}</span>
          <select
            className="cloud-input cloud-create-snapshot"
            value={draft.snapshot_id ?? ""}
            disabled={draft.submitting}
            onKeyDown={onKeyDown}
            onChange={(event) => store.updateDraft({ snapshot_id: event.target.value || undefined })}
          >
            <option value="">{t(L.createBaseImage)}</option>
            {draft.snapshots?.map((snapshot) => (
              <option key={snapshot.id} value={snapshot.id}>
                {snapshot.name || snapshot.id}
              </option>
            ))}
          </select>
        </label>
        {plan?.maxActiveVms !== undefined && plan.maxActiveVms !== null && (
          <p className={`cloud-plan-limit${limited ? " reached" : ""}`}>
            {format(t(limited ? L.createLimitReached : L.createLimit), {
              used,
              limit: plan.maxActiveVms,
              plan: plan.planId ?? "",
            })}
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
