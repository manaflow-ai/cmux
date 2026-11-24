import { DialogButton } from "../../ui/DialogButton";
import { Sheet } from "../../ui/Sheet";
import type { Strings } from "../shared/i18n";
import type { CloudStore, SurgeDraft } from "./store";
import { errorText, format, L } from "./strings";

const COUNTS = [1, 2, 3, 4, 5, 6, 7, 8];
const MINUTES = [5, 15, 30, 60];
const STATUS = { created: L.surgeCreated, queued: L.surgeQueued, refused: L.surgeRefused } as const;

export function SurgeSheet({ store, draft, strings }: { store: CloudStore; draft: SurgeDraft; strings: Strings }) {
  const { t } = strings;
  const ready = draft.preview?.available === true;
  const waiting = draft.pending !== undefined;
  const machineMinutes = draft.preview ? (draft.preview.count * draft.preview.ttl_seconds) / 60 : 0;
  return (
    <Sheet
      open
      onOpenChange={(open) => !open && store.closeSurge()}
      label={t(L.surge)}
      side="top"
      className="ui-glass ui-glass-floats cloud-create-sheet"
      backdropClassName="cloud-sheet-backdrop"
    >
      <h2 className="cloud-sheet-title">{t(L.surge)}</h2>
      <label className="cloud-field">
        <span className="cloud-field-label">{t(L.machines)}</span>
        <select
          className="cloud-input"
          value={draft.args.count}
          disabled={draft.sent}
          onChange={(event) => store.updateSurge({ count: Number(event.target.value) })}
        >
          {COUNTS.map((count) => (
            <option key={count} value={count}>
              {count}
            </option>
          ))}
        </select>
      </label>
      <label className="cloud-field">
        <span className="cloud-field-label">{t(L.surgeDuration)}</span>
        <select
          className="cloud-input"
          value={draft.args.ttl_seconds}
          disabled={draft.sent}
          onChange={(event) => store.updateSurge({ ttl_seconds: Number(event.target.value) })}
        >
          {MINUTES.map((minutes) => (
            <option key={minutes} value={minutes * 60}>
              {format(t(L.surgeMinutes), { minutes })}
            </option>
          ))}
        </select>
      </label>
      {draft.preview && !draft.result && (
        <div aria-live="polite">
          {ready && <p>{format(t(L.surgeMachineMinutes), { minutes: machineMinutes })}</p>}
          {draft.preview.provider && <p>{format(t(L.surgePlacement), { provider: draft.preview.provider })}</p>}
          {draft.preview.reason && <p className="cloud-muted">{draft.preview.reason}</p>}
        </div>
      )}
      {draft.result && (
        <ul aria-live="polite">
          {draft.result.slots.map((slot) => (
            <li key={slot.index}>
              {format(t(L.surgeSlot), { number: slot.index + 1, status: t(STATUS[slot.status]) })}
              {slot.provider && <div>{slot.provider}</div>}
              {slot.reason && <div className="cloud-muted">{slot.reason}</div>}
            </li>
          ))}
        </ul>
      )}
      {draft.error && (
        <p className="cloud-sheet-error" role="alert">
          {errorText(draft.error, draft.errorCode, t)}
        </p>
      )}
      <div className="cloud-sheet-actions">
        <DialogButton
          dialogKey="escape"
          className="cloud-button"
          disabled={draft.pending === "create"}
          onClick={() => store.closeSurge()}
        >
          {t(draft.result || draft.sent ? L.envClose : L.cancel)}
        </DialogButton>
        {!draft.result && (
          <>
            {!draft.sent && (
              <DialogButton
                dialogKey={ready ? null : "return"}
                className="cloud-button cloud-surge-preview"
                disabled={waiting}
                onClick={() => void store.previewSurge()}
              >
                {t(draft.pending === "preview" ? L.loading : L.surgePreview)}
              </DialogButton>
            )}
            {ready && (
              <DialogButton
                dialogKey="return"
                className="cloud-button primary cloud-surge-submit"
                disabled={waiting}
                onClick={() => void store.submitSurge()}
              >
                {t(draft.pending === "create" ? L.createSubmitting : draft.sent ? L.retry : L.surgeStart)}
              </DialogButton>
            )}
          </>
        )}
      </div>
    </Sheet>
  );
}
