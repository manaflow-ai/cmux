"use client";

// Client half of the device dashboard. Renders the joined registry +
// control-plane view and owns the three mutations (revoke, restore, remove).
// Display states derive from stored ground truth at render time (spec rule:
// store only ground truth — lease expiry and version floors are computed
// here, never persisted).

import { useCallback, useMemo, useState } from "react";
import { useLocale, useTranslations } from "next-intl";

import {
  versionBelowFloor,
  type DeviceDashboardData,
  type DeviceDashboardEntry,
} from "@/services/devices/dashboard";

/** Seeded entries silent this long display as stale ("needs update / open the
 * app once"); derived, the stored status stays seeded. */
const STALE_AFTER_MS = 7 * 24 * 60 * 60 * 1000;

type DisplayState =
  | "revoked"
  | "retired"
  | "active"
  | "seeded"
  | "stale"
  | "suspended"
  | "pending"
  | "superseded"
  | "unenrolled";

type MutationKind = "revoke" | "restore" | "retire";

export function DevicesView({
  initialData,
  initialNowIso,
}: {
  initialData: DeviceDashboardData;
  initialNowIso: string;
}) {
  const t = useTranslations("dashboard.devices");
  const locale = useLocale();
  const [data, setData] = useState<DeviceDashboardData>(initialData);
  const [nowIso, setNowIso] = useState(initialNowIso);
  const [showRetired, setShowRetired] = useState(false);
  const [pending, setPending] = useState<string | null>(null);
  const [confirming, setConfirming] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  const refresh = useCallback(async (): Promise<void> => {
    setRefreshing(true);
    try {
      const response = await fetch("/api/devices/dashboard", { cache: "no-store" });
      if (!response.ok) throw new Error(`refresh_${response.status}`);
      setData(await response.json() as DeviceDashboardData);
      setNowIso(new Date().toISOString());
      setError(null);
    } catch {
      setError(t("refreshFailed"));
    } finally {
      setRefreshing(false);
    }
  }, [t]);

  const mutate = useCallback(async (
    kind: MutationKind,
    endpointId: string,
  ): Promise<void> => {
    setPending(endpointId);
    setConfirming(null);
    setError(null);
    try {
      const path = kind === "retire"
        ? "/api/devices/dashboard/retire"
        : "/api/devices/dashboard/revoke";
      const body = kind === "retire"
        ? { endpointId }
        : { endpointId, revoked: kind === "revoke" };
      const response = await fetch(path, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      });
      if (!response.ok) {
        const payload: unknown = await response.json().catch(() => null);
        const code = payload !== null && typeof payload === "object"
          && typeof (payload as { error?: unknown }).error === "string"
          ? (payload as { error: string }).error
          : `http_${response.status}`;
        throw new Error(code);
      }
      await refresh();
    } catch (cause) {
      const code = cause instanceof Error ? cause.message : "unknown";
      setError(t("mutationFailed", { code }));
      setPending(null);
      return;
    }
    setPending(null);
  }, [refresh, t]);

  const now = Date.parse(nowIso);
  const entries = useMemo(
    () => data.devices.map((entry) => decorate(entry, data, now)),
    [data, now],
  );
  const visible = entries.filter((entry) => showRetired || entry.state !== "retired");
  const retiredCount = entries.length - visible.length;
  const macs = visible.filter((entry) => entry.device.platform === "mac");
  const phones = visible.filter((entry) => entry.device.platform === "ios");
  const other = visible.filter((entry) => entry.device.platform === null);
  const connectedCount = entries.filter((entry) => entry.device.listAuth?.connected).length;
  const behindCount = entries.filter((entry) => entry.sync === "behind").length;
  const updateRequired = entries.filter((entry) => entry.updateRequired);

  const dateFormatter = new Intl.DateTimeFormat(locale, {
    dateStyle: "medium",
    timeStyle: "short",
  });

  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h1 className="text-sm font-medium">{t("title")}</h1>
            <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
          </div>
          <button
            type="button"
            onClick={() => void refresh()}
            disabled={refreshing}
            className="shrink-0 border border-border px-2 py-1 text-xs text-muted hover:text-foreground disabled:opacity-50"
          >
            {refreshing ? t("refreshing") : t("refresh")}
          </button>
        </div>
      </div>

      {error !== null ? (
        <div className="mb-4 border border-border bg-code-bg p-3 text-xs" role="alert">
          {error}
        </div>
      ) : null}

      {!data.controlPlaneAvailable ? (
        <section className="mb-4 border border-border p-3">
          <h2 className="text-sm font-medium">{t("controlPlaneDownTitle")}</h2>
          <p className="mt-1 max-w-2xl text-xs text-muted">{t("controlPlaneDownBody")}</p>
        </section>
      ) : null}

      <section className="mb-4 grid gap-3 sm:grid-cols-4">
        <StatTile label={t("statDevices")} value={String(entries.length)} />
        <StatTile label={t("statConnected")} value={String(connectedCount)} />
        <StatTile
          label={t("statRevision")}
          value={data.rev !== null ? `r${data.rev}` : "—"}
        />
        <StatTile
          label={t("statBehind")}
          value={String(behindCount)}
          emphasized={behindCount > 0}
        />
      </section>

      {updateRequired.length > 0 ? (
        <section className="mb-4 border border-border p-3">
          <h2 className="text-sm font-medium">{t("updateRequiredTitle")}</h2>
          <ul className="mt-1 space-y-0.5 text-xs text-muted">
            {updateRequired.map((entry) => (
              <li key={entry.device.endpointId}>
                {t("updateRequiredRow", {
                  name: displayName(entry.device, t("unnamedDevice")),
                  version: entry.device.listAuth?.appVersion ?? "?",
                  floor: entry.floor ?? "?",
                })}
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      <VersionSpread entries={entries} />

      <DeviceGroup
        title={t("macsTitle")}
        entries={macs}
        emptyLabel={t("noMacs")}
        rev={data.rev}
        pending={pending}
        confirming={confirming}
        setConfirming={setConfirming}
        mutate={mutate}
        dateFormatter={dateFormatter}
        now={now}
      />
      <DeviceGroup
        title={t("phonesTitle")}
        entries={phones}
        emptyLabel={t("noPhones")}
        rev={data.rev}
        pending={pending}
        confirming={confirming}
        setConfirming={setConfirming}
        mutate={mutate}
        dateFormatter={dateFormatter}
        now={now}
      />
      {other.length > 0 ? (
        <DeviceGroup
          title={t("otherTitle")}
          entries={other}
          emptyLabel=""
          rev={data.rev}
          pending={pending}
          confirming={confirming}
          setConfirming={setConfirming}
          mutate={mutate}
          dateFormatter={dateFormatter}
          now={now}
        />
      ) : null}

      <div className="mt-3 flex items-center justify-between text-xs text-muted">
        <p className="max-w-2xl">{t("leaseFootnote")}</p>
        {retiredCount > 0 || showRetired ? (
          <button
            type="button"
            onClick={() => setShowRetired((value) => !value)}
            className="shrink-0 border border-border px-2 py-1 hover:text-foreground"
          >
            {showRetired
              ? t("hideRemoved")
              : t("showRemoved", { count: retiredCount })}
          </button>
        ) : null}
      </div>
    </div>
  );
}

interface DecoratedEntry {
  device: DeviceDashboardEntry;
  state: DisplayState;
  sync: "synced" | "behind" | "never" | "none";
  updateRequired: boolean;
  floor: string | null;
}

function decorate(
  device: DeviceDashboardEntry,
  data: DeviceDashboardData,
  now: number,
): DecoratedEntry {
  const listAuth = device.listAuth;
  const floor = device.platform !== null
    ? data.minimumSupportedVersion?.[device.platform] ?? null
    : null;
  const updateRequired = listAuth?.appVersion != null && floor !== null
    && !listAuth.revoked && listAuth.status !== "retired"
    && versionBelowFloor(listAuth.appVersion, floor);

  let state: DisplayState;
  if (listAuth === null) {
    state = "unenrolled";
  } else if (listAuth.revoked) {
    state = "revoked";
  } else if (listAuth.status === "seeded") {
    const lastMovement = device.lastSeenAt !== null ? Date.parse(device.lastSeenAt) : Number.NaN;
    state = Number.isNaN(lastMovement) || now - lastMovement > STALE_AFTER_MS
      ? "stale"
      : "seeded";
  } else {
    state = listAuth.status;
  }

  let sync: DecoratedEntry["sync"];
  if (listAuth === null || data.rev === null) {
    sync = "none";
  } else if (listAuth.lastAckedRev === null) {
    sync = "never";
  } else if (listAuth.lastAckedRev >= data.rev) {
    sync = "synced";
  } else {
    sync = "behind";
  }

  return { device, state, sync, updateRequired, floor };
}

function displayName(device: DeviceDashboardEntry, fallback: string): string {
  if (device.displayName) return device.displayName;
  if (device.deviceId) return device.deviceId.slice(0, 8);
  return `${fallback} ${device.endpointId.slice(0, 8)}`;
}

function StatTile({
  label,
  value,
  emphasized = false,
}: {
  label: string;
  value: string;
  emphasized?: boolean;
}) {
  return (
    <div className="border border-border p-3">
      <div className="text-xs text-muted">{label}</div>
      <div className={`mt-1 text-lg ${emphasized ? "font-semibold" : ""}`}>{value}</div>
    </div>
  );
}

/** Version + track distribution straight from the list, so deprecations and
 * floor raises are data-driven instead of guessed. */
function VersionSpread({ entries }: { entries: readonly DecoratedEntry[] }) {
  const t = useTranslations("dashboard.devices");
  const counts = new Map<string, number>();
  for (const entry of entries) {
    const listAuth = entry.device.listAuth;
    if (!listAuth || entry.state === "retired") continue;
    const track = listAuth.releaseTrack ?? t("unknownTrack");
    const version = listAuth.appVersion ?? t("unknownVersion");
    const platform = entry.device.platform ?? "?";
    const key = `${platform} · ${track} · ${version}`;
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  if (counts.size === 0) return null;
  const rows = [...counts.entries()].sort((a, b) => b[1] - a[1]);
  const total = rows.reduce((sum, [, count]) => sum + count, 0);
  return (
    <section className="mb-4 border border-border p-3">
      <h2 className="text-sm font-medium">{t("versionSpreadTitle")}</h2>
      <p className="mt-1 text-xs text-muted">{t("versionSpreadBody")}</p>
      <div className="mt-2 space-y-1">
        {rows.map(([key, count]) => (
          <div key={key} className="flex items-center gap-2 text-xs">
            <span className="w-56 shrink-0 truncate font-mono">{key}</span>
            <span className="w-8 shrink-0 text-right text-muted">{count}</span>
            <span
              aria-hidden="true"
              className="h-2 bg-foreground/60"
              style={{ width: `${Math.max(4, Math.round((count / total) * 240))}px` }}
            />
          </div>
        ))}
      </div>
    </section>
  );
}

function DeviceGroup({
  title,
  entries,
  emptyLabel,
  rev,
  pending,
  confirming,
  setConfirming,
  mutate,
  dateFormatter,
  now,
}: {
  title: string;
  entries: readonly DecoratedEntry[];
  emptyLabel: string;
  rev: number | null;
  pending: string | null;
  confirming: string | null;
  setConfirming: (endpointId: string | null) => void;
  mutate: (kind: MutationKind, endpointId: string) => Promise<void>;
  dateFormatter: Intl.DateTimeFormat;
  now: number;
}) {
  return (
    <section className="mb-4">
      <h2 className="mb-2 text-sm font-medium">{title}</h2>
      {entries.length === 0 ? (
        <p className="border border-border p-3 text-xs text-muted">{emptyLabel}</p>
      ) : (
        <div className="border border-border">
          {entries.map((entry) => (
            <DeviceRow
              key={entry.device.endpointId}
              entry={entry}
              rev={rev}
              pending={pending}
              confirming={confirming}
              setConfirming={setConfirming}
              mutate={mutate}
              dateFormatter={dateFormatter}
              now={now}
            />
          ))}
        </div>
      )}
    </section>
  );
}

function DeviceRow({
  entry,
  rev,
  pending,
  confirming,
  setConfirming,
  mutate,
  dateFormatter,
  now,
}: {
  entry: DecoratedEntry;
  rev: number | null;
  pending: string | null;
  confirming: string | null;
  setConfirming: (endpointId: string | null) => void;
  mutate: (kind: MutationKind, endpointId: string) => Promise<void>;
  dateFormatter: Intl.DateTimeFormat;
  now: number;
}) {
  const t = useTranslations("dashboard.devices");
  const { device, state, sync } = entry;
  const listAuth = device.listAuth;
  const busy = pending !== null;
  const isPending = pending === device.endpointId;
  const isConfirming = confirming === device.endpointId;
  const confirmedAt = listAuth?.lastConfirmedAt ?? null;
  const seenAt = device.lastSeenAt ?? confirmedAt;

  return (
    <div className="border-b border-border p-3 last:border-b-0">
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
        <span
          role="img"
          aria-label={listAuth?.connected ? t("connectedNow") : t("notConnected")}
          title={listAuth?.connected ? t("connectedNow") : t("notConnected")}
          className={`inline-block size-2 shrink-0 rounded-full ${
            listAuth?.connected ? "bg-foreground" : "border border-border"
          }`}
        />
        <span className="min-w-0 truncate text-sm font-medium">
          {displayName(device, t("unnamedDevice"))}
        </span>
        <StateBadge state={state} />
        {entry.updateRequired ? (
          <span className="border border-border px-1.5 py-0.5 text-[11px] font-semibold">
            {t("badgeUpdateRequired")}
          </span>
        ) : null}
        {device.tag && device.tag !== "default" ? (
          <span className="border border-border px-1.5 py-0.5 font-mono text-[11px] text-muted">
            {device.tag}
          </span>
        ) : null}
        <span className="ml-auto flex shrink-0 items-center gap-2">
          {listAuth !== null ? (
            isConfirming ? (
              <>
                <span className="text-xs">{t("confirmRevoke")}</span>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => void mutate("revoke", device.endpointId)}
                  className="border border-border px-2 py-1 text-xs font-semibold hover:bg-code-bg disabled:opacity-50"
                >
                  {isPending ? t("working") : t("confirmRevokeYes")}
                </button>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => setConfirming(null)}
                  className="border border-border px-2 py-1 text-xs text-muted hover:text-foreground disabled:opacity-50"
                >
                  {t("confirmRevokeNo")}
                </button>
              </>
            ) : listAuth.revoked ? (
              <button
                type="button"
                disabled={busy}
                onClick={() => void mutate("restore", device.endpointId)}
                className="border border-border px-2 py-1 text-xs hover:bg-code-bg disabled:opacity-50"
              >
                {isPending ? t("working") : t("restore")}
              </button>
            ) : (
              <button
                type="button"
                disabled={busy}
                onClick={() => setConfirming(device.endpointId)}
                className="border border-border px-2 py-1 text-xs hover:bg-code-bg disabled:opacity-50"
              >
                {t("revoke")}
              </button>
            )
          ) : null}
          {listAuth !== null && !listAuth.revoked && state !== "retired" && !isConfirming
            && !listAuth.connected ? (
            <button
              type="button"
              disabled={busy}
              onClick={() => void mutate("retire", device.endpointId)}
              title={t("removeHint")}
              className="border border-border px-2 py-1 text-xs text-muted hover:text-foreground disabled:opacity-50"
            >
              {isPending ? t("working") : t("remove")}
            </button>
          ) : null}
        </span>
      </div>

      <div className="mt-1.5 flex flex-wrap gap-x-4 gap-y-0.5 text-xs text-muted">
        <span>
          {listAuth?.appVersion != null
            ? t("versionCell", {
              version: listAuth.appVersion,
              track: listAuth.releaseTrack ?? t("unknownTrack"),
            })
            : t("versionUnknown")}
        </span>
        <span>
          {sync === "synced" && rev !== null
            ? t("syncSynced", { rev })
            : sync === "behind" && listAuth?.lastAckedRev != null && rev !== null
              ? t("syncBehind", { acked: listAuth.lastAckedRev, rev })
              : sync === "never"
                ? t("syncNever")
                : t("syncNone")}
        </span>
        <span>
          {seenAt !== null
            ? t("lastSeen", {
              when: relativeOrAbsolute(seenAt, now, dateFormatter),
            })
            : t("neverSeen")}
        </span>
        <span className="font-mono" title={device.endpointId}>
          {device.endpointId.slice(0, 12)}…
        </span>
      </div>

      {state === "seeded" || state === "stale" ? (
        <p className="mt-1.5 max-w-2xl text-xs text-muted">{t("seededExplainer")}</p>
      ) : null}
      {state === "revoked" ? (
        <p className="mt-1.5 max-w-2xl text-xs text-muted">{t("revokedExplainer")}</p>
      ) : null}
      {state === "unenrolled" ? (
        <p className="mt-1.5 max-w-2xl text-xs text-muted">{t("unenrolledExplainer")}</p>
      ) : null}
    </div>
  );
}

function StateBadge({ state }: { state: DisplayState }) {
  const t = useTranslations("dashboard.devices");
  const labels: Record<DisplayState, string> = {
    revoked: t("stateRevoked"),
    retired: t("stateRemoved"),
    active: t("stateActive"),
    seeded: t("stateSeeded"),
    stale: t("stateStale"),
    suspended: t("stateSuspended"),
    pending: t("statePending"),
    superseded: t("stateSuperseded"),
    unenrolled: t("stateUnenrolled"),
  };
  const emphasized = state === "revoked";
  const warned = state === "seeded" || state === "stale";
  return (
    <span
      className={`border px-1.5 py-0.5 text-[11px] ${
        emphasized
          ? "border-foreground font-semibold"
          : warned
            ? "border-border text-muted"
            : "border-border text-muted"
      }`}
    >
      {warned ? "△ " : ""}
      {labels[state]}
    </span>
  );
}

function relativeOrAbsolute(
  iso: string,
  now: number,
  dateFormatter: Intl.DateTimeFormat,
): string {
  const at = Date.parse(iso);
  if (Number.isNaN(at)) return iso;
  const deltaMs = now - at;
  if (deltaMs < 60_000) return "<1m";
  if (deltaMs < 3_600_000) return `${Math.floor(deltaMs / 60_000)}m`;
  if (deltaMs < 86_400_000) return `${Math.floor(deltaMs / 3_600_000)}h`;
  if (deltaMs < 7 * 86_400_000) return `${Math.floor(deltaMs / 86_400_000)}d`;
  return dateFormatter.format(new Date(at));
}
