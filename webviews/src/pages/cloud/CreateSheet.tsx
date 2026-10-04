// The create sheet: name, size (plan sizes; sizes outside the plan are shown but disabled),
// snapshot (base image or a team snapshot) and the plan's machine limit. The draft holds one
// idempotency key, so a double submit or a retry creates one machine. Plain Return submits and
// Escape closes; chords are ignored.
import type { KeyboardEvent } from "react";
import type { Strings } from "../shared/i18n";
import { atMachineLimit, plain, sizeSpec } from "./model";
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
  const used = state.machines.filter((machine) => machine.status !== "destroyed").length;
  const canSubmit = !draft.submitting && !!draft.size && !limited;
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
            disabled={draft.submitting}
            aria-label={t(L.createName)}
            ref={focusOnMount}
            onKeyDown={onKeyDown}
            onChange={(event) => store.updateDraft({ name: event.target.value })}
          />
        </label>
        <fieldset className="cloud-field cloud-size-choices" disabled={draft.submitting}>
          <legend className="cloud-field-label">{t(L.createSize)}</legend>
          {plan?.sizes.map((size) => (
            <label key={size.name} className={`cloud-size-choice${size.allowed ? "" : " unavailable"}`}>
              <input
                type="radio"
                name="cloud-size"
                value={size.name}
                checked={draft.size === size.name}
                disabled={!size.allowed}
                aria-label={size.name}
                onKeyDown={onKeyDown}
                onChange={() => store.updateDraft({ size: size.name })}
              />
              <span className="cloud-size-name">{size.name}</span>
              <span className="cloud-size-spec">{sizeSpec(size, t, language)}</span>
              {!size.allowed && <span className="cloud-badge">{t(L.sizeNotInPlan)}</span>}
            </label>
          ))}
        </fieldset>
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
        {plan && (
          <p className={`cloud-plan-limit${limited ? " reached" : ""}`}>
            {format(t(limited ? L.createLimitReached : L.createLimit), {
              used,
              limit: plan.machine_limit,
              plan: plan.name,
            })}
          </p>
        )}
        {draft.error && (
          <p className="cloud-sheet-error" role="alert">
            {draft.error}
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
