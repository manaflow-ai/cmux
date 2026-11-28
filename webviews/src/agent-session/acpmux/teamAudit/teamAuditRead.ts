// Team's reads and the words every view shares (TeamAuditScreen.tsx, TeamAuditViews.tsx): one
// read of `_acpmux/team_audit` (or the export stub, usageExport.ts) per params, the status under it,
// a row's name and its agent time.
import { useEffect, useRef, useState } from "react";
import type { StringKey, Translate } from "../i18n";
import { isOlderDaemon } from "../queue/queueModel";
import {
  auditHasRows,
  auditRowLabel,
  readTeamAudit,
  TEAM_AUDIT_NONE,
  type TeamAuditAnswer,
  type TeamAuditReply,
  type TeamAuditRow,
  type TeamAuditTotals,
} from "./teamAuditModel";
import { USAGE_OTHERS_KEY, type UsageGroup } from "./usageExport";

export type Load = (params: Record<string, unknown>) => Promise<unknown>;

/// One read's outcome: the audit, why there is none, or an acpmux that predates the method.
export type AuditResult = TeamAuditAnswer | { kind: "older" };

/// A read of `params` (undefined: none): its result once it answered, and while the next read runs
/// the last reply, so a table or a tile keeps its place instead of blinking empty.
export type AuditRead = {
  result?: AuditResult;
  /// The reply on screen: this read's, or while it runs the last one.
  reply?: TeamAuditReply;
  loading: boolean;
  retry(): void;
};

export function useAuditRead(load: Load, params: Record<string, unknown> | undefined): AuditRead {
  const key = params ? JSON.stringify(params) : undefined;
  const [state, setState] = useState<{ key?: string; result?: AuditResult; reply?: TeamAuditReply }>({});
  const [attempt, setAttempt] = useState(0);
  const loadRef = useRef(load);
  useEffect(() => {
    loadRef.current = load;
  }, [load]);
  useEffect(() => {
    if (!key) return;
    // A reply after the page left, or after the next pick, is dropped.
    let live = true;
    loadRef.current(JSON.parse(key) as Record<string, unknown>).then(
      (value) => {
        if (!live) return;
        const answer = readTeamAudit(value);
        setState((previous) => ({
          key,
          result: answer,
          reply: answer.kind === "ready" ? answer.reply : previous.reply,
        }));
      },
      (error: unknown) => {
        if (live)
          setState((previous) => ({
            ...previous,
            key,
            result: isOlderDaemon(error) ? { kind: "older" } : { kind: "failed" },
          }));
      },
    );
    return () => {
      live = false;
    };
  }, [key, attempt]);
  // The answer counts only for the params it was read for: a pick shows loading in the same render.
  const result = state.key === key ? state.result : undefined;
  return {
    result,
    reply: result ? (result.kind === "ready" ? result.reply : undefined) : state.reply,
    loading: Boolean(key) && !result,
    retry: () => {
      setState((previous) => ({ reply: previous.reply }));
      setAttempt((n) => n + 1);
    },
  };
}

export const GROUP_KEY: Record<UsageGroup, StringKey> = {
  team: "teamAudit.group.team",
  project: "teamAudit.group.project",
  // Its own word: History > Costs groups by person and machine, one machine's ledger.
  person: "teamAudit.group.person",
  repo: "ledger.group.repo",
  model: "ledger.group.model",
  harness: "teamAudit.group.harness",
  machine: "teamAudit.group.machine",
  day: "ledger.group.day",
  session: "ledger.group.session",
};
export const REASON_KEY: Record<Exclude<AuditResult["kind"], "ready">, StringKey> = {
  signedOut: "teamAudit.signedOut",
  off: "teamAudit.off",
  notShared: "teamAudit.notShared",
  failed: "teamAudit.failed",
  older: "teamAudit.older",
};

/// The status line under a read: why there is nothing, loading, empty, or nothing to say.
export function readStatus(read: AuditRead, t: Translate): string {
  if (read.result && read.result.kind !== "ready") return t(REASON_KEY[read.result.kind]);
  if (!read.reply) return t("ledger.loading");
  return auditHasRows(read.reply) ? "" : t("teamAudit.empty");
}

/// A row's name: the platform's `none` and the privacy fold in the page's words.
export function rowName(group: UsageGroup, row: TeamAuditRow, locale: string, t: Translate): string {
  if (row.key === TEAM_AUDIT_NONE) return t("teamAudit.none");
  if (row.key === USAGE_OTHERS_KEY) return t("teamAudit.others");
  return auditRowLabel(group, row, locale);
}

const MINUTE = 60_000;

/// Agent time: the export's minutes where it sends them, else the audit's wall time.
export const agentMs = (totals: TeamAuditTotals) =>
  totals.agentMinutes !== undefined ? totals.agentMinutes * MINUTE : totals.wallMs;
