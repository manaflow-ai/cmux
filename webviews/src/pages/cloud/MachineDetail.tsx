// The selected machine: header (rename, connect, pause or resume, delete), overview (size with the
// plan's sizes, idle policy) and stats, then the sections in DetailSections.tsx. Delete asks the
// host's native confirmation. Rename is page view state until the user saves it.
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
  StatusLabel,
  type MachineRow,
} from "./model";
import type { CloudPlan } from "./ops";
import type { CloudStore } from "./store";
import { L } from "./strings";

export interface DetailProps {
  store: CloudStore;
  row: MachineRow;
  detail: MachineDetail;
  plan?: CloudPlan;
  strings: Strings;
}

// Stable callback ref: React calls it only when the rename field mounts, so later renders (watch
// events) do not pull focus back to it.
const focusOnMount = (node: HTMLInputElement | null) => node?.focus();

export function MachineDetailView({ store, row, detail, plan, strings }: DetailProps) {
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
          <select
            className="cloud-input cloud-resize"
            value={machine.size?.name ?? ""}
            disabled={busy || !plan}
            onChange={(event) => void store.resize(machine.id, event.target.value)}
          >
            {!plan?.sizes.some((size) => size.name === machine.size?.name) && (
              <option value={machine.size?.name ?? ""}>{machine.size?.name ?? "-"}</option>
            )}
            {plan?.sizes.map((size) => (
              <option key={size.name} value={size.name} disabled={!size.allowed}>
                {size.allowed ? size.name : `${size.name} (${t(L.sizeNotInPlan)})`}
              </option>
            ))}
          </select>
        </dd>
        <dt>{t(L.fieldIdle)}</dt>
        <dd>
          <select
            className="cloud-input cloud-idle"
            value={String(machine.idle_timeout_seconds ?? "")}
            disabled={busy}
            onChange={(event) =>
              void store.setIdlePolicy(machine.id, event.target.value ? Number(event.target.value) : null)
            }
          >
            {machine.idle_timeout_seconds && !IDLE_CHOICES.includes(machine.idle_timeout_seconds) && (
              <option value={machine.idle_timeout_seconds}>{idleLabel(machine.idle_timeout_seconds, t)}</option>
            )}
            {IDLE_CHOICES.map((seconds) => (
              <option key={String(seconds)} value={seconds ?? ""}>
                {idleLabel(seconds, t)}
              </option>
            ))}
          </select>
        </dd>
        {machine.image && (
          <>
            <dt>{t(L.fieldImage)}</dt>
            <dd>{[machine.image, machine.image_version].filter(Boolean).join(" ")}</dd>
          </>
        )}
        {(machine.address?.ipv4 || machine.address?.ipv6) && (
          <>
            <dt>{t(L.fieldAddress)}</dt>
            <dd className="cloud-mono">{machine.address.ipv4 ?? machine.address.ipv6}</dd>
          </>
        )}
        {machine.created_at_ms && (
          <>
            <dt>{t(L.fieldCreated)}</dt>
            <dd>{formatDate(machine.created_at_ms, language)}</dd>
          </>
        )}
      </dl>

      <div className="cloud-subsection-header">
        <h3 className="cloud-subsection-title">{t(L.stats)}</h3>
        <button type="button" className="cloud-link-button" onClick={() => void store.detail.reload("stats")}>
          {t(L.refresh)}
        </button>
      </div>
      {stats?.state === "running" ? (
        <div className="cloud-stats">
          <Meter label={t(L.statCpu)} value={stats.cpu_percent} text={`${Math.round(stats.cpu_percent ?? 0)}%`} />
          <Meter
            label={t(L.statMemory)}
            value={percent(stats.memory_used_mb, stats.memory_total_mb)}
            text={`${formatMegabytes(stats.memory_used_mb ?? 0, t, language)} / ${formatMegabytes(stats.memory_total_mb ?? 0, t, language)}`}
          />
          <Meter
            label={t(L.statDisk)}
            value={percent(stats.disk_used_mb, stats.disk_total_mb)}
            text={`${formatMegabytes(stats.disk_used_mb ?? 0, t, language)} / ${formatMegabytes(stats.disk_total_mb ?? 0, t, language)}`}
          />
        </div>
      ) : (
        <p className="cloud-muted">{detail.loading ? t(L.loading) : t(L.statsAsleep)}</p>
      )}

      <SnapshotsSection store={store} machine={machine.id} detail={detail} strings={strings} />
      <PublicationsSection store={store} machine={machine.id} detail={detail} strings={strings} />
      <DomainsSection store={store} detail={detail} strings={strings} />
      <NetworkSection store={store} machine={machine.id} detail={detail} strings={strings} />
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
