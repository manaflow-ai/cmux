// The selected machine: header (rename, connect, pause or resume, fork, delete), overview (size from
// the stats with a memory resize from the plan's options, idle policy) and stats, then the sections
// in DetailSections.tsx. Delete asks the host's native confirmation. Rename is page view state
// until the user saves it. An op the owner does not serve yet shows "Not available yet".
import { useState, type KeyboardEvent } from "react";
import type { Strings } from "../shared/i18n";
import type { MachineDetail } from "./detail";
import { DomainsSection, NetworkSection, PublicationsSection, SnapshotsSection } from "./DetailSections";
import {
  canPause,
  canResume,
  formatDate,
  formatMegabytes,
  IDLE_CHOICES,
  idleLabel,
  IntentLabel,
  percent,
  plain,
  sizeSpec,
  StatusLabel,
  type MachineRow,
} from "./model";
import { CloudOps, type CloudPlan } from "./ops";
import type { CloudStore } from "./store";
import { L } from "./strings";

export interface DetailProps {
  store: CloudStore;
  row: MachineRow;
  detail: MachineDetail;
  plan?: CloudPlan;
  /** Ops the owner does not serve yet. */
  unavailable: readonly string[];
  strings: Strings;
}

// Stable callback ref: React calls it only when the rename field mounts, so later renders (watch
// events) do not pull focus back to it.
const focusOnMount = (node: HTMLInputElement | null) => node?.focus();

export function MachineDetailView({ store, row, detail, plan, unavailable, strings }: DetailProps) {
  const { t, language } = strings;
  const machine = row.machine!;
  const [renaming, setRenaming] = useState<string | null>(null);
  const busy = !!row.pending;
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
  const stats = detail.stats;
  const awake = stats?.state === "awake";
  const memory = awake ? (stats.memoryTotalMb ?? undefined) : undefined;
  const memoryChoices = [
    ...(plan?.memoryOptionsMb ?? []).map((mb) => ({ mb, allowed: true })),
    ...(plan?.lockedMemoryOptionsMb ?? []).map((mb) => ({ mb, allowed: false })),
  ];
  const idleUnavailable = unavailable.includes(CloudOps.machineIdlePolicySet);
  return (
    <section className="cloud-detail" aria-labelledby="cloud-detail-title">
      <div className="cloud-detail-header">
        <span className={`cloud-status-dot status-${row.status}${busy ? " pending" : ""}`} aria-hidden="true" />
        {renaming === null ? (
          <h2 id="cloud-detail-title" className="cloud-detail-title">
            {row.title}
          </h2>
        ) : (
          <input
            className="cloud-input cloud-rename-input"
            value={renaming}
            aria-label={t(L.rename)}
            ref={focusOnMount}
            onChange={(event) => setRenaming(event.target.value)}
            onKeyDown={renameKeys}
          />
        )}
        <span className="cloud-detail-status">
          {t(row.pending ? IntentLabel[row.pending] : StatusLabel[row.status])}
        </span>
        <div className="cloud-detail-actions">
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
          <button type="button" className="cloud-button" onClick={() => void store.connect(machine.id)}>
            {t(L.connect)}
          </button>
          <button
            type="button"
            className="cloud-button cloud-machine-fork"
            disabled={busy}
            onClick={() => void store.forkMachine(machine.id)}
          >
            {t(L.fork)}
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
        </div>
      </div>

      <h3 className="cloud-subsection-title">{t(L.overview)}</h3>
      <dl className="cloud-fields">
        <dt>{t(L.fieldId)}</dt>
        <dd className="cloud-mono">{machine.id}</dd>
        <dt>{t(L.fieldSize)}</dt>
        <dd>
          {awake && <span className="cloud-size-spec">{sizeSpec(stats, t, language)}</span>}
          {memoryChoices.length > 0 && (
            <select
              className="cloud-input cloud-resize"
              aria-label={t(L.fieldSize)}
              value={memory ?? ""}
              disabled={busy}
              onChange={(event) => event.target.value && void store.resize(machine.id, Number(event.target.value))}
            >
              {(memory === undefined || !memoryChoices.some((choice) => choice.mb === memory)) && (
                <option value={memory ?? ""}>{memory ? formatMegabytes(memory, t, language) : "-"}</option>
              )}
              {memoryChoices.map(({ mb, allowed }) => (
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
          {idleUnavailable ? (
            <span className="cloud-muted cloud-unavailable">{t(L.unavailable)}</span>
          ) : (
            <select
              className="cloud-input cloud-idle"
              defaultValue=""
              disabled={busy}
              onChange={(event) =>
                void store.setIdlePolicy(machine.id, event.target.value ? Number(event.target.value) : null)
              }
            >
              {IDLE_CHOICES.map((seconds) => (
                <option key={String(seconds)} value={seconds ?? ""}>
                  {idleLabel(seconds, t)}
                </option>
              ))}
            </select>
          )}
        </dd>
        {machine.image && (
          <>
            <dt>{t(L.fieldImage)}</dt>
            <dd>{[machine.image, machine.imageVersion].filter(Boolean).join(" ")}</dd>
          </>
        )}
        {(machine.address?.ipv4 || machine.address?.ipv6) && (
          <>
            <dt>{t(L.fieldAddress)}</dt>
            <dd className="cloud-mono">{machine.address.ipv4 || machine.address.ipv6}</dd>
          </>
        )}
        {!!machine.createdAt && (
          <>
            <dt>{t(L.fieldCreated)}</dt>
            <dd>{formatDate(machine.createdAt, language)}</dd>
          </>
        )}
      </dl>

      <div className="cloud-subsection-header">
        <h3 className="cloud-subsection-title">{t(L.stats)}</h3>
        <button type="button" className="cloud-link-button" onClick={() => void store.detail.reload("stats")}>
          {t(L.refresh)}
        </button>
      </div>
      {awake ? (
        <div className="cloud-stats">
          <Meter
            label={t(L.statCpu)}
            value={stats.cpuPercent ?? undefined}
            text={`${Math.round(stats.cpuPercent ?? 0)}%`}
          />
          <Meter
            label={t(L.statMemory)}
            value={percent(stats.memoryUsedMb, stats.memoryTotalMb)}
            text={`${formatMegabytes(stats.memoryUsedMb ?? 0, t, language)} / ${formatMegabytes(stats.memoryTotalMb ?? 0, t, language)}`}
          />
          <Meter
            label={t(L.statDisk)}
            value={percent(stats.diskUsedMb, stats.diskTotalMb)}
            text={`${formatMegabytes(stats.diskUsedMb ?? 0, t, language)} / ${formatMegabytes(stats.diskTotalMb ?? 0, t, language)}`}
          />
        </div>
      ) : (
        <p className="cloud-muted">{detail.loading ? t(L.loading) : t(L.statsAsleep)}</p>
      )}

      <SnapshotsSection
        store={store}
        machine={machine.id}
        detail={detail}
        unavailable={unavailable}
        strings={strings}
      />
      <PublicationsSection
        store={store}
        machine={machine.id}
        detail={detail}
        unavailable={unavailable}
        strings={strings}
      />
      <DomainsSection store={store} detail={detail} unavailable={unavailable} strings={strings} />
      <NetworkSection store={store} machine={machine.id} detail={detail} unavailable={unavailable} strings={strings} />
    </section>
  );
}

function Meter({ label, value, text }: { label: string; value?: number; text: string }) {
  return (
    <div className="cloud-meter">
      <span className="cloud-meter-label">{label}</span>
      <span className="cloud-meter-track" aria-hidden="true">
        <span className="cloud-meter-fill" style={{ width: `${value ?? 0}%` }} />
      </span>
      <span className="cloud-meter-text">{text}</span>
    </div>
  );
}
