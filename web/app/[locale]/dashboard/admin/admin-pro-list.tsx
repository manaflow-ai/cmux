"use client";

import { useFormatter, useTranslations } from "next-intl";
import { useRef, useState } from "react";

type GrantRecord = {
  readonly plan: string | null;
  readonly byUserId: string;
  readonly byEmail: string | null;
  readonly at: string;
} | null;

type Subscriber = {
  readonly userId: string;
  readonly email: string | null;
  readonly subscriptionId: string;
  readonly status: string;
  readonly cancelAtPeriodEnd: boolean;
  readonly currentPeriodEnd: string | null;
};

type TeamSubscription = {
  readonly teamId: string;
  readonly displayName: string | null;
  readonly subscriptionId: string;
  readonly status: string;
  readonly seats: number | null;
  readonly cancelAtPeriodEnd: boolean;
  readonly currentPeriodEnd: string | null;
};

type PendingGrant = {
  readonly id: string;
  readonly email: string;
  readonly plan: string;
  readonly grantedByEmail: string | null;
  readonly createdAt: string;
};

type UserGrant = {
  readonly userId: string;
  readonly email: string | null;
  readonly emailVerified: boolean;
  readonly plan: string;
  readonly lastGrant: GrantRecord;
};

type TeamGrant = {
  readonly teamId: string;
  readonly displayName: string;
  readonly plan: string;
  readonly lastGrant: GrantRecord;
};

type Snapshot = {
  readonly subscribers: readonly Subscriber[];
  readonly teamSubscriptions: readonly TeamSubscription[];
  readonly pendingGrants: readonly PendingGrant[];
  readonly truncated: {
    readonly subscribers: boolean;
    readonly teamSubscriptions: boolean;
    readonly pendingGrants: boolean;
  };
};

/** The server-rendered roster, passed from the page so nothing waits on a button. */
export type ProListSnapshotProps = Snapshot;

type ScanState = {
  readonly status: "idle" | "scanning" | "done" | "error";
  readonly scanned: number;
  readonly pages: number;
  readonly message?: string;
};

type ListState =
  | { readonly kind: "idle" }
  | { readonly kind: "loading" }
  | { readonly kind: "error"; readonly message: string }
  | {
      readonly kind: "loaded";
      readonly snapshot: Snapshot;
      readonly userGrants: readonly UserGrant[];
      readonly teamGrants: readonly TeamGrant[];
      readonly userScan: ScanState;
      readonly teamScan: ScanState;
      readonly loadedAt: string;
    };

type Translate = ReturnType<typeof useTranslations<"dashboard.admin">>;

/** Hard stop so a runaway cursor cannot loop forever. */
const MAX_SCAN_PAGES = 200;

const buttonClass =
  "border border-border bg-background px-2.5 py-1 text-xs font-medium text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:bg-background disabled:hover:text-foreground";

export function AdminProList({
  initialSnapshot,
  onPickQuery,
}: {
  initialSnapshot: Snapshot | null;
  onPickQuery?: (query: string) => void;
}) {
  const t = useTranslations("dashboard.admin");
  const [state, setState] = useState<ListState>(() =>
    initialSnapshot
      ? loadedState(initialSnapshot)
      : { kind: "error", message: t("errors.billing") },
  );
  const runSeq = useRef(0);
  const started = useRef(false);

  // Streams the directory scans as soon as the section is on screen. A
  // callback ref runs once per mount without an effect; reload restarts it.
  function startOnMount(node: HTMLElement | null) {
    if (!node || started.current) return;
    started.current = true;
    if (initialSnapshot) {
      const seq = ++runSeq.current;
      void walk("users", seq);
      void walk("teams", seq);
    } else {
      void load();
    }
  }

  async function load() {
    const seq = ++runSeq.current;
    setState({ kind: "loading" });
    let response: Response;
    try {
      response = await fetch("/api/admin/pro-users", { headers: { accept: "application/json" } });
    } catch {
      if (seq === runSeq.current) setState({ kind: "error", message: t("errors.network") });
      return;
    }
    if (seq !== runSeq.current) return;
    if (!response.ok) {
      setState({ kind: "error", message: errorMessage(t, response.status) });
      return;
    }
    let snapshot: Snapshot;
    try {
      snapshot = (await response.json()) as Snapshot;
    } catch {
      if (seq === runSeq.current) setState({ kind: "error", message: t("errors.generic") });
      return;
    }
    if (seq !== runSeq.current) return;
    setState(loadedState(snapshot));
    // Manual grants need a directory walk; run both walks after the snapshot
    // is on screen so the Stripe list is never blocked on them.
    void walk("users", seq);
    void walk("teams", seq);
  }

  async function walk(kind: "users" | "teams", seq: number) {
    let cursor: string | null = null;
    let pages = 0;
    let scanned = 0;
    while (pages < MAX_SCAN_PAGES) {
      if (seq !== runSeq.current) return;
      const params = new URLSearchParams({ kind });
      if (cursor) params.set("cursor", cursor);
      let response: Response;
      try {
        response = await fetch(`/api/admin/pro-users/scan?${params}`, { headers: { accept: "application/json" } });
      } catch {
        patchScan(kind, seq, { status: "error", scanned, pages, message: t("errors.network") });
        return;
      }
      if (seq !== runSeq.current) return;
      if (!response.ok) {
        patchScan(kind, seq, { status: "error", scanned, pages, message: errorMessage(t, response.status) });
        return;
      }
      let page: { rows: unknown[]; scanned: number; nextCursor: string | null };
      try {
        page = (await response.json()) as typeof page;
      } catch {
        patchScan(kind, seq, { status: "error", scanned, pages, message: t("errors.generic") });
        return;
      }
      if (seq !== runSeq.current) return;
      const nextPages = pages + 1;
      const nextScanned = scanned + page.scanned;
      const rows = page.rows;
      setState((current) => {
        if (current.kind !== "loaded") return current;
        return kind === "users"
          ? { ...current, userGrants: [...current.userGrants, ...(rows as UserGrant[])], userScan: { status: "scanning", scanned: nextScanned, pages: nextPages } }
          : { ...current, teamGrants: [...current.teamGrants, ...(rows as TeamGrant[])], teamScan: { status: "scanning", scanned: nextScanned, pages: nextPages } };
      });
      pages = nextPages;
      scanned = nextScanned;
      cursor = page.nextCursor;
      if (!cursor) break;
    }
    patchScan(kind, seq, {
      status: pages >= MAX_SCAN_PAGES && cursor ? "error" : "done",
      scanned,
      pages,
      message: pages >= MAX_SCAN_PAGES && cursor ? t("list.scanTruncated") : undefined,
    });
  }

  // Only the run that started this scan may update it; a reload starts a new
  // sequence and results from the old fetches are dropped.
  function patchScan(kind: "users" | "teams", seq: number, scan: ScanState) {
    if (seq !== runSeq.current) return;
    setState((current) => {
      if (current.kind !== "loaded") return current;
      return kind === "users" ? { ...current, userScan: scan } : { ...current, teamScan: scan };
    });
  }

  return (
    <section ref={startOnMount} className="border border-border p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="text-sm font-medium">{t("list.title")}</h2>
          <p className="mt-1 max-w-2xl text-muted">{t("list.description")}</p>
        </div>
        <button
          type="button"
          onClick={() => void load()}
          disabled={state.kind === "loading"}
          className={buttonClass}
        >
          {state.kind === "loading" ? t("list.loading") : t("list.reload")}
        </button>
      </div>

      {state.kind === "error" ? (
        <p className="mt-3 border border-border p-3 text-sm text-muted" role="alert">{state.message}</p>
      ) : null}

      {state.kind === "loaded" ? (
        <LoadedList t={t} state={state} onPickQuery={onPickQuery} />
      ) : null}
    </section>
  );
}

function LoadedList({
  t,
  state,
  onPickQuery,
}: {
  t: Translate;
  state: Extract<ListState, { kind: "loaded" }>;
  onPickQuery?: (query: string) => void;
}) {
  const format = useFormatter();
  const { snapshot, userGrants, teamGrants, userScan, teamScan } = state;
  const totalUsers = snapshot.subscribers.length + userGrants.length;
  const totalTeams = snapshot.teamSubscriptions.length + teamGrants.length;
  return (
    <div className="mt-3 space-y-4">
      <div className="flex flex-wrap gap-2 text-xs">
        <Stat label={t("list.stats.proUsers")} value={String(totalUsers)} />
        <Stat label={t("list.stats.subscribers")} value={String(snapshot.subscribers.length)} />
        <Stat label={t("list.stats.userGrants")} value={String(userGrants.length)} pending={userScan.status === "scanning"} />
        <Stat label={t("list.stats.teams")} value={String(totalTeams)} pending={teamScan.status === "scanning"} />
        <Stat label={t("list.stats.pending")} value={String(snapshot.pendingGrants.length)} />
      </div>

      <ScanNote t={t} scan={userScan} label={t("list.scanUsers")} />
      <ScanNote t={t} scan={teamScan} label={t("list.scanTeams")} />
      {snapshot.truncated.subscribers || snapshot.truncated.teamSubscriptions || snapshot.truncated.pendingGrants ? (
        <p className="border border-border p-2 text-xs text-muted" role="alert">{t("list.truncated")}</p>
      ) : null}

      <Block title={t("list.sections.subscribers", { count: snapshot.subscribers.length })}>
        {snapshot.subscribers.length === 0 ? (
          <Empty text={t("list.empty")} />
        ) : (
          <table className="w-full min-w-[40rem] text-left text-xs">
            <thead className="border-b border-border text-muted">
              <tr>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.email")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.stripe")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("list.periodEnd")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("list.userId")}</th>
              </tr>
            </thead>
            <tbody>
              {snapshot.subscribers.map((row) => (
                <tr key={row.subscriptionId} className="border-b border-border last:border-b-0">
                  <td className="px-3 py-2 font-mono text-foreground">
                    <PickButton value={row.email ?? row.userId} label={row.email ?? t("results.noEmail")} onPickQuery={onPickQuery} />
                  </td>
                  <td className="px-3 py-2 text-muted">
                    {row.status}{row.cancelAtPeriodEnd ? ` · ${t("results.cancelling")}` : ""}
                  </td>
                  <td className="px-3 py-2 text-muted">{row.currentPeriodEnd ? formatTime(format, row.currentPeriodEnd) : "—"}</td>
                  <td className="px-3 py-2 font-mono text-[10px] text-muted">{row.userId}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Block>

      <Block title={t("list.sections.userGrants", { count: userGrants.length })}>
        {userGrants.length === 0 ? (
          <Empty text={userScan.status === "scanning" ? t("list.scanning") : t("list.empty")} />
        ) : (
          <table className="w-full min-w-[40rem] text-left text-xs">
            <thead className="border-b border-border text-muted">
              <tr>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.email")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.plan")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.grant")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("list.userId")}</th>
              </tr>
            </thead>
            <tbody>
              {userGrants.map((row) => (
                <tr key={row.userId} className="border-b border-border last:border-b-0">
                  <td className="px-3 py-2 font-mono text-foreground">
                    <PickButton value={row.email ?? row.userId} label={row.email ?? t("results.noEmail")} onPickQuery={onPickQuery} />
                    <span className="ml-2 text-muted">{row.emailVerified ? t("results.verified") : t("results.unverified")}</span>
                  </td>
                  <td className="px-3 py-2 text-muted">{row.plan}</td>
                  <td className="px-3 py-2 text-muted">
                    {row.lastGrant
                      ? t("grant.by", { who: row.lastGrant.byEmail ?? row.lastGrant.byUserId, when: formatTime(format, row.lastGrant.at) })
                      : t("grant.none")}
                  </td>
                  <td className="px-3 py-2 font-mono text-[10px] text-muted">{row.userId}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Block>

      <Block title={t("list.sections.teams", { count: totalTeams })}>
        {totalTeams === 0 ? (
          <Empty text={teamScan.status === "scanning" ? t("list.scanning") : t("list.empty")} />
        ) : (
          <table className="w-full min-w-[40rem] text-left text-xs">
            <thead className="border-b border-border text-muted">
              <tr>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.team")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("list.source")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("list.detail")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("list.teamId")}</th>
              </tr>
            </thead>
            <tbody>
              {snapshot.teamSubscriptions.map((row) => (
                <tr key={`sub-${row.subscriptionId}`} className="border-b border-border last:border-b-0">
                  <td className="px-3 py-2 text-foreground">
                    <PickButton value={row.displayName ?? row.teamId} label={row.displayName ?? row.teamId} onPickQuery={onPickQuery} />
                  </td>
                  <td className="px-3 py-2 text-muted">{t("list.sourceStripe")}</td>
                  <td className="px-3 py-2 text-muted">
                    {row.status}{row.cancelAtPeriodEnd ? ` · ${t("results.cancelling")}` : ""}
                    {row.seats !== null ? ` · ${t("list.seats", { count: row.seats })}` : ""}
                    {row.currentPeriodEnd ? ` · ${formatTime(format, row.currentPeriodEnd)}` : ""}
                  </td>
                  <td className="px-3 py-2 font-mono text-[10px] text-muted">{row.teamId}</td>
                </tr>
              ))}
              {teamGrants.map((row) => (
                <tr key={`grant-${row.teamId}`} className="border-b border-border last:border-b-0">
                  <td className="px-3 py-2 text-foreground">
                    <PickButton value={row.displayName} label={row.displayName} onPickQuery={onPickQuery} />
                  </td>
                  <td className="px-3 py-2 text-muted">{t("list.sourceGrant")}</td>
                  <td className="px-3 py-2 text-muted">
                    {row.plan}
                    {row.lastGrant ? ` · ${t("grant.by", { who: row.lastGrant.byEmail ?? row.lastGrant.byUserId, when: formatTime(format, row.lastGrant.at) })}` : ""}
                  </td>
                  <td className="px-3 py-2 font-mono text-[10px] text-muted">{row.teamId}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Block>

      <Block title={t("list.sections.pending", { count: snapshot.pendingGrants.length })}>
        {snapshot.pendingGrants.length === 0 ? (
          <Empty text={t("list.empty")} />
        ) : (
          <table className="w-full min-w-[36rem] text-left text-xs">
            <thead className="border-b border-border text-muted">
              <tr>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.email")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.plan")}</th>
                <th scope="col" className="px-3 py-2 font-medium">{t("results.grant")}</th>
              </tr>
            </thead>
            <tbody>
              {snapshot.pendingGrants.map((row) => (
                <tr key={row.id} className="border-b border-border last:border-b-0">
                  <td className="px-3 py-2 font-mono text-foreground">
                    <PickButton value={row.email} label={row.email} onPickQuery={onPickQuery} />
                  </td>
                  <td className="px-3 py-2 text-muted">{row.plan}</td>
                  <td className="px-3 py-2 text-muted">
                    {t("grant.by", { who: row.grantedByEmail ?? "?", when: formatTime(format, row.createdAt) })}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Block>
    </div>
  );
}

function loadedState(snapshot: Snapshot): Extract<ListState, { kind: "loaded" }> {
  return {
    kind: "loaded",
    snapshot: {
      subscribers: snapshot.subscribers ?? [],
      teamSubscriptions: snapshot.teamSubscriptions ?? [],
      pendingGrants: snapshot.pendingGrants ?? [],
      truncated: {
        subscribers: snapshot.truncated?.subscribers === true,
        teamSubscriptions: snapshot.truncated?.teamSubscriptions === true,
        pendingGrants: snapshot.truncated?.pendingGrants === true,
      },
    },
    userGrants: [],
    teamGrants: [],
    userScan: { status: "scanning", scanned: 0, pages: 0 },
    teamScan: { status: "scanning", scanned: 0, pages: 0 },
    loadedAt: new Date().toISOString(),
  };
}

function Stat({ label, value, pending }: { label: string; value: string; pending?: boolean }) {
  return (
    <div className="border border-border px-2.5 py-1.5">
      <div className="text-[10px] uppercase tracking-wide text-muted">{label}</div>
      <div className="font-mono text-sm text-foreground">{value}{pending ? "…" : ""}</div>
    </div>
  );
}

function ScanNote({ t, scan, label }: { t: Translate; scan: ScanState; label: string }) {
  if (scan.status === "idle") return null;
  const text = scan.status === "scanning"
    ? t("list.scanProgress", { label, scanned: scan.scanned })
    : scan.status === "done"
      ? t("list.scanDone", { label, scanned: scan.scanned })
      : `${t("list.scanFailed", { label, scanned: scan.scanned })} ${scan.message ?? ""}`;
  return (
    <p className="text-xs text-muted" role={scan.status === "error" ? "alert" : undefined}>{text}</p>
  );
}

function Block({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div>
      <h3 className="mb-1 text-xs font-semibold text-foreground">{title}</h3>
      <div className="overflow-x-auto border border-border">{children}</div>
    </div>
  );
}

function Empty({ text }: { text: string }) {
  return <p className="p-3 text-xs text-muted">{text}</p>;
}

function PickButton({
  value,
  label,
  onPickQuery,
}: {
  value: string;
  label: string;
  onPickQuery?: (query: string) => void;
}) {
  if (!onPickQuery) return <>{label}</>;
  return (
    <button
      type="button"
      onClick={() => onPickQuery(value)}
      className="underline decoration-dotted underline-offset-2 hover:decoration-solid focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
    >
      {label}
    </button>
  );
}

function formatTime(format: ReturnType<typeof useFormatter>, iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  return format.dateTime(date, { dateStyle: "medium" });
}

function errorMessage(t: Translate, status: number): string {
  if (status === 401 || status === 403) return t("errors.forbidden");
  if (status === 503) return t("errors.billing");
  return t("errors.generic");
}
