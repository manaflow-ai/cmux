import { useState } from "react";
import type { Checkpoint, CheckpointList } from "./protocol";
import type { CheckpointStrings } from "./strings";
import "./styles.css";

/** The checked list is the Create intent. All receipts and omissions come from the Git owner. */
export function CheckpointReview({
  list,
  record,
  busy,
  error,
  strings: s,
  variant = "compact",
  onCreate,
  onRefresh,
  onCopy,
  onKeep,
  onRelease,
  onCancel,
}: {
  list?: CheckpointList;
  record?: Checkpoint;
  busy?: string;
  error?: string;
  strings: CheckpointStrings;
  variant?: "compact" | "expanded";
  onCreate: (paths: string[]) => void;
  onRefresh: () => void;
  onCopy: (record: Checkpoint) => Promise<void>;
  onKeep: (record: Checkpoint) => void;
  onRelease: (record: Checkpoint, pinId: string) => void;
  onCancel: () => void;
}) {
  const [selection, setSelection] = useState<{ list: CheckpointList; paths: ReadonlySet<string> }>();
  const [copied, setCopied] = useState(false);
  const candidates = list?.candidates ?? [];
  const selected =
    selection?.list === list
      ? selection.paths
      : new Set(candidates.filter((candidate) => candidate.eligible).map((candidate) => candidate.path));
  const toggle = (path: string) => {
    if (!list) return;
    const paths = new Set(selected);
    if (paths.has(path)) paths.delete(path);
    else paths.add(path);
    setSelection({ list, paths });
  };
  const reason = (code?: string) => {
    if (code === "ignored") return s.ignored;
    if (code === "not_selected") return s.notSelected;
    if (code === "excluded" || code === "credential_excluded") return s.excluded;
    if (code === "over_limit" || code === "too_large" || code === "file_too_large") return s.tooLarge;
    return s.unavailableFile;
  };
  const count = (value: number) => new Intl.NumberFormat().format(value);
  const date = (value: string) => {
    const timestamp = new Date(value);
    return Number.isFinite(timestamp.getTime())
      ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(timestamp)
      : s.unavailable;
  };
  const pins = record?.pins ?? [];
  const userPins = pins.filter((pin) => !pin.pin_id.startsWith("handoff:") && !pin.pin_id.startsWith("restore:"));
  return (
    <section className="acpmux-checkpoint-review" data-variant={variant} aria-label={s.title}>
      <header>
        <strong>{s.title}</strong>
        <button type="button" onClick={onCancel} disabled={!!busy}>{s.cancel}</button>
      </header>
      {record ? (
        <div className="acpmux-checkpoint-receipt">
          <p className="acpmux-checkpoint-fidelity" data-complete={record.complete}>
            {record.complete ? s.complete : s.partial}
          </p>
          <dl className="acpmux-checkpoint-facts">
            <div><dt>{s.reference}</dt><dd><code>{record.ref}</code></dd></div>
            <div><dt>{s.base}</dt><dd>{record.base.head?.slice(0, 12) ?? s.noHead}</dd></div>
            <div><dt>{s.created}</dt><dd>{date(record.created_at)}</dd></div>
            <div><dt>{s.included}</dt><dd>{count(record.coverage.included)}</dd></div>
            <div><dt>{s.omitted}</dt><dd>{count(record.coverage.omitted)}</dd></div>
            <div><dt>{s.unavailable}</dt><dd>{count(record.coverage.unavailable)}</dd></div>
            <div><dt>{s.bytes}</dt><dd>{count(record.bytes.logical)}</dd></div>
            <div><dt>{pins.length ? s.retained : s.expires}</dt><dd>{pins.length ? s.pinned : record.expires_at ? date(record.expires_at) : s.unavailable}</dd></div>
          </dl>
          {record.skipped_total > 0 && (
            <details open={variant === "expanded"}>
              <summary>{s.skipped} · {count(record.skipped_total)}</summary>
              <ul>{record.skipped.map((file, index) => <li key={`${file.path}:${index}`}><code>{file.path}</code><span>{reason(file.code)}</span></li>)}</ul>
            </details>
          )}
          <div className="acpmux-checkpoint-actions">
            <button type="button" disabled={!!busy} onClick={() => {
              setCopied(false);
              void onCopy(record).then(() => setCopied(true)).catch(() => undefined);
            }}>{copied ? s.copied : s.copyReference}</button>
            <button type="button" disabled={!!busy || pins.length > 0} onClick={() => onKeep(record)}>{s.keep}</button>
            {userPins.map((pin) => <button type="button" key={pin.pin_id} disabled={!!busy} onClick={() => onRelease(record, pin.pin_id)}>{s.release}</button>)}
          </div>
          {!pins.length && <p className="acpmux-checkpoint-hint">{s.manualRetention}</p>}
        </div>
      ) : (
        <form onSubmit={(event) => { event.preventDefault(); if (list && !busy) onCreate([...selected]); }}>
          <fieldset disabled={!!busy || !list}>
            <legend>{s.untracked}</legend>
            {list && !candidates.some((candidate) => candidate.eligible) && <p>{s.emptyUntracked}</p>}
            <ul className="acpmux-checkpoint-candidates">
              {candidates.map((candidate) => <li key={candidate.path}>
                <label><input type="checkbox" checked={candidate.eligible && selected.has(candidate.path)} disabled={!candidate.eligible} onChange={() => toggle(candidate.path)} /><code>{candidate.path}</code></label>
                <span>{candidate.eligible ? count(candidate.bytes) : reason(candidate.reason)}</span>
              </li>)}
            </ul>
          </fieldset>
          <div className="acpmux-checkpoint-actions">
            <button type="submit" disabled={!!busy || !list}>{s.create}</button>
            <button type="button" disabled={!!busy} onClick={onRefresh}>{s.refresh}</button>
          </div>
        </form>
      )}
      {busy && <output>{busy === "creating" ? s.creating : s.loading}</output>}
      {error && <p role="alert">{error}</p>}
    </section>
  );
}
