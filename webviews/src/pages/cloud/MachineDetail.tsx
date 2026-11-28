// The selected machine: header (rename, connect, pause or resume, delete), overview (size from the
// record with a memory resize from the plan's sizes, idle policy, image, created), then the sections
// in DetailSections.tsx, PortsSection.tsx and FilesSection.tsx. Delete and resize ask the host's
// native confirmation. A classic machine (contract 4) is read-only: a "Classic" badge, its overview
// and snapshots, and Upgrade (a native action) once the user moved their classic machines. Rename is
// page view state until the user saves it. An op the owner does not serve yet shows "Not available
// yet".
import { useState, type KeyboardEvent } from "react";
import type { Strings } from "../shared/i18n";
import { canUpgradeClassic } from "./account";
import type { MachineDetail } from "./detail";
import { SnapshotsSection } from "./DetailSections";
import { FilesSection } from "./FilesSection";
import { PortsSection } from "./PortsSection";
import {
  canPause,
  canResume,
  changeable,
  formatDate,
  formatMegabytes,
  IDLE_CHOICES,
  idleLabel,
  IntentLabel,
  memoryChoices,
  plain,
  sizeSpec,
  StatusLabel,
  transitional,
  type MachineRow,
} from "./model";
import { CloudOps, type CloudPlan, type MigrationStatus } from "./ops";
import type { CloudStore } from "./store";
import { L } from "./strings";
import type { FileTransfer } from "./transfers";

export interface DetailProps {
  store: CloudStore;
  row: MachineRow;
  detail: MachineDetail;
  plan?: CloudPlan;
  migration?: MigrationStatus;
  /** Ops the owner does not serve yet. */
  unavailable: readonly string[];
  /** This session's file transfers (all machines; the Files section shows this machine's). */
  transfers: readonly FileTransfer[];
  strings: Strings;
}

// Stable callback ref: React calls it only when the rename field mounts, so later renders (watch
// events) do not pull focus back to it.
const focusOnMount = (node: HTMLInputElement | null) => node?.focus();

export function MachineDetailView({
  store,
  row,
  detail,
  plan,
  migration,
  unavailable,
  transfers,
  strings,
}: DetailProps) {
  const { t, language } = strings;
  const machine = row.machine!;
  const classic = !!row.classic;
  const [renaming, setRenaming] = useState<string | null>(null);
  const busy = !changeable(row);
  const saveRename = () => {
    if (renaming !== null) void store.rename(machine.id, renaming);
    setRenaming(null);
  };
  const renameKeys = (event: KeyboardEvent) => {
    if (!plain(event)) return;
    if (event.key === "Enter") saveRename();
    else if (event.key === "Escape") setRenaming(null);
    else return;
    event.preventDefault();
    event.stopPropagation();
  };
  const memory = machine.size?.memory_mb ?? undefined;
  const choices = memoryChoices(plan);
  const idle = machine.idle_policy?.idle_seconds ?? 0;
  const idleChoices = IDLE_CHOICES.some((seconds) => (seconds ?? 0) === idle) ? IDLE_CHOICES : [...IDLE_CHOICES, idle];
  return (
    <section className="cloud-detail" aria-labelledby="cloud-detail-title">
      <div className="cloud-detail-header">
        <span
          className={`cloud-status-dot status-${row.status}${row.pending || transitional(row.status) ? " pending" : ""}`}
          aria-hidden="true"
        />
        {renaming === null ? (
          <h2 id="cloud-detail-title" className="cloud-detail-title">
            {row.title}
          </h2>
        ) : (
          <input
            className="cloud-input cloud-rename-input"
            value={renaming}
            maxLength={80}
            aria-label={t(L.rename)}
            ref={focusOnMount}
            onChange={(event) => setRenaming(event.target.value)}
            onKeyDown={renameKeys}
          />
        )}
        {classic && <span className="cloud-badge cloud-classic-badge">{t(L.classic)}</span>}
        <span className="cloud-detail-status">
          {t(row.pending ? IntentLabel[row.pending] : StatusLabel[row.status])}
        </span>
        <div className="cloud-detail-actions">
          {classic ? (
            canUpgradeClassic(migration) && (
              <button
                type="button"
                className="cloud-button primary cloud-machine-upgrade"
                disabled={!!row.pending}
                onClick={() => void store.upgrade(machine.id)}
              >
                {t(L.upgradeMachine)}
              </button>
            )
          ) : (
            <>
              {renaming === null ? (
                <button type="button" className="cloud-button" disabled={busy} onClick={() => setRenaming(row.title)}>
                  {t(L.rename)}
                </button>
              ) : (
                <>
                  <button type="button" className="cloud-button" onClick={() => setRenaming(null)}>
                    {t(L.cancel)}
                  </button>
                  <button type="button" className="cloud-button primary" onClick={saveRename}>
                    {t(L.save)}
                  </button>
                </>
              )}
              <button
                type="button"
                className="cloud-button cloud-machine-connect"
                onClick={() => void store.connect(machine.id)}
              >
                {t(L.connect)}
              </button>
              {canPause(row) && (
                <button type="button" className="cloud-button" onClick={() => void store.pause(machine.id)}>
                  {t(L.pause)}
                </button>
              )}
              {canResume(row) && (
                <button type="button" className="cloud-button" onClick={() => void store.resume(machine.id)}>
                  {t(L.resume)}
                </button>
              )}
              <button
                type="button"
                className="cloud-button destructive cloud-machine-delete"
                disabled={busy}
                onClick={() => void store.requestDelete(machine.id)}
              >
                {t(L.delete)}
              </button>
            </>
          )}
        </div>
      </div>
      {classic && <p className="cloud-muted cloud-classic-note">{t(L.classicReadOnly)}</p>}

      <h3 className="cloud-subsection-title">{t(L.overview)}</h3>
      <dl className="cloud-fields">
        <dt>{t(L.fieldId)}</dt>
        <dd className="cloud-mono">{machine.id}</dd>
        <dt>{t(L.fieldSize)}</dt>
        <dd>
          {machine.size && <span className="cloud-size-spec">{sizeSpec(machine.size, t, language)}</span>}
          {!classic && choices.length > 0 && (
            <select
              className="cloud-input cloud-resize"
              aria-label={t(L.fieldSize)}
              value={memory ?? ""}
              disabled={busy}
              onChange={(event) => event.target.value && void store.resize(machine.id, Number(event.target.value))}
            >
              {(memory === undefined || !choices.some((choice) => choice.mb === memory)) && (
                <option value={memory ?? ""}>{memory ? formatMegabytes(memory, t, language) : "-"}</option>
              )}
              {choices.map(({ mb, allowed }) => (
                <option key={mb} value={mb} disabled={!allowed}>
                  {allowed
                    ? formatMegabytes(mb, t, language)
                    : `${formatMegabytes(mb, t, language)} (${t(L.sizeNotInPlan)})`}
                </option>
              ))}
            </select>
          )}
        </dd>
        <dt>{t(L.fieldIdle)}</dt>
        <dd>
          {classic || unavailable.includes(CloudOps.machineIdlePolicySet) ? (
            <span className={classic ? "cloud-idle-value" : "cloud-muted cloud-unavailable"}>
              {classic ? idleLabel(idle, t) : t(L.unavailable)}
            </span>
          ) : (
            <select
              className="cloud-input cloud-idle"
              value={idle}
              disabled={busy}
              onChange={(event) => void store.setIdlePolicy(machine.id, Number(event.target.value) || null)}
            >
              {idleChoices.map((seconds) => (
                <option key={String(seconds)} value={seconds ?? 0}>
                  {idleLabel(seconds, t)}
                </option>
              ))}
            </select>
          )}
        </dd>
        {machine.image && (
          <>
            <dt>{t(L.fieldImage)}</dt>
            <dd>{[machine.image.id, machine.image.daemon_version].filter(Boolean).join(" ")}</dd>
          </>
        )}
        {!!machine.created_at && (
          <>
            <dt>{t(L.fieldCreated)}</dt>
            <dd>{formatDate(machine.created_at, language)}</dd>
          </>
        )}
      </dl>

      <SnapshotsSection
        store={store}
        machine={machine.id}
        detail={detail}
        unavailable={unavailable}
        strings={strings}
        readOnly={classic}
      />
      {!classic && (
        <>
          <PortsSection
            store={store}
            machine={machine.id}
            title={row.title}
            detail={detail}
            unavailable={unavailable}
            strings={strings}
          />
          <FilesSection
            store={store}
            detail={detail}
            unavailable={unavailable}
            transfers={transfers}
            strings={strings}
          />
        </>
      )}
    </section>
  );
}
