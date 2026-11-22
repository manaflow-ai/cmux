import { useCallback, useEffect, useRef, useState } from "react";
import type { Translate } from "./i18n";
import type { SessionAuthQuery } from "./sessionAuth";

/// Setup's provider sign-in for one chosen target, as acpmux observes it (`_acpmux/login_flow`,
/// cmux-tui/crates/acpmux/src/login_flow.rs). Opening the login terminal is not a sign-in: the
/// flow waits, and only acpmux's own check of the target (the one a send runs) says `succeeded`.
export type LoginFlowPhase = "starting" | "waiting" | "verifying" | "succeeded" | "failed" | "cancelled" | "expired";
export type LoginFlowTarget = { harness: string; host?: string; cwd?: string; routeId?: string };
export type LoginFlow = {
  flowId: string;
  phase: LoginFlowPhase;
  target: LoginFlowTarget;
  startedAt: number;
  expiresAt: number;
  /** One of acpmux's fixed reason words (`login_flow::reason`), never a provider's text. */
  reason?: string;
};
/// `_acpmux/login_flow` through the client; undefined when the daemon or the pane's host has none.
export type LoginFlowCall = (params: Record<string, unknown>) => Promise<unknown>;

const phases = new Set<LoginFlowPhase>([
  "starting",
  "waiting",
  "verifying",
  "succeeded",
  "failed",
  "cancelled",
  "expired",
]);

export const loginFlowEnded = (phase: LoginFlowPhase | undefined) =>
  phase === "succeeded" || phase === "failed" || phase === "cancelled" || phase === "expired";

export function readLoginFlow(reply: unknown): LoginFlow | undefined {
  if (!reply || typeof reply !== "object") return undefined;
  const row = reply as Record<string, unknown>;
  const target = row.target as Record<string, unknown> | undefined;
  if (
    typeof row.flowId !== "string" ||
    !row.flowId ||
    !phases.has(row.phase as LoginFlowPhase) ||
    !target ||
    typeof target.harness !== "string" ||
    typeof row.startedAt !== "number" ||
    typeof row.expiresAt !== "number"
  )
    return undefined;
  const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);
  const host = text(target.host);
  const cwd = text(target.cwd);
  const routeId = text(target.routeId);
  const reason = text(row.reason);
  return {
    flowId: row.flowId,
    phase: row.phase as LoginFlowPhase,
    target: {
      harness: target.harness,
      ...(host ? { host } : {}),
      ...(cwd ? { cwd } : {}),
      ...(routeId ? { routeId } : {}),
    },
    startedAt: row.startedAt,
    expiresAt: row.expiresAt,
    ...(reason ? { reason } : {}),
  };
}

/// The flow's target for a `_acpmux/session/auth` target query (the composer's chosen machine,
/// harness profile and folder); none for a session query (a chat signs in through its own card).
export function loginFlowTarget(query: SessionAuthQuery | undefined): LoginFlowTarget | undefined {
  if (!query || !("target" in query)) return undefined;
  return query.target;
}

/// What the composer's sign-in note says while a flow runs, and after it ends.
export function loginFlowText(flow: LoginFlow, t: Translate): string {
  switch (flow.phase) {
    case "starting":
      return t("loginFlow.starting");
    case "waiting":
      return flow.reason === "peer_unreachable" ? t("loginFlow.waitingMachine") : t("loginFlow.waiting");
    case "verifying":
      return t("loginFlow.verifying");
    case "succeeded":
      return t("loginFlow.succeeded");
    case "failed":
      return flow.reason === "open_failed" ? t("loginFlow.openFailed") : t("loginFlow.failed");
    case "cancelled":
      return t("loginFlow.cancelled");
    case "expired":
      return t("loginFlow.expired");
  }
}

/// How often a waiting flow asks acpmux to check again, besides each time the window takes focus.
export const LOGIN_FLOW_CHECK_MS = 4000;

/// Runs one observed sign-in for `target`: `begin` starts (or, after an end, restarts) the flow,
/// opens the login with `open` (the terminal tab, the fallback the composer always had) and then
/// checks until acpmux says it ended. `begin` resolves false when there is no flow to run (an older
/// daemon, a host that does not relay it): the caller opens the plain login as before.
export function useLoginFlow(
  call: LoginFlowCall | undefined,
  target: LoginFlowTarget | undefined,
  open: (() => Promise<boolean>) | undefined,
) {
  const [flow, setFlow] = useState<LoginFlow>();
  const key = target ? JSON.stringify(target) : "";
  const live = useRef<string | undefined>(undefined);
  // Another machine, profile or folder chosen: the flow on screen is not this target's.
  useEffect(() => {
    setFlow((previous) => (previous && JSON.stringify(previous.target) !== key ? undefined : previous));
  }, [key]);
  const answer = useCallback((reply: unknown, id?: string) => {
    const next = readLoginFlow(reply);
    if (!next || (id && next.flowId !== id) || (live.current && next.flowId !== live.current)) return undefined;
    setFlow(next);
    return next;
  }, []);
  const begin = useCallback(async (): Promise<boolean> => {
    if (!call || !target || !open) return false;
    let started: LoginFlow | undefined;
    try {
      started = readLoginFlow(await call({ op: "start", target, restart: loginFlowEnded(flow?.phase) }));
    } catch {
      return false;
    }
    if (!started) return false;
    live.current = started.flowId;
    setFlow(started);
    if (started.phase !== "starting") {
      // Setup reopened over a flow still waiting: open the login again, the flow stands.
      if (started.phase === "waiting") void open();
      return true;
    }
    const opened = await open().catch(() => false);
    await call({ op: opened ? "opened" : "openFailed", flowId: started.flowId })
      .then((reply) => answer(reply, started.flowId))
      .catch(() => undefined);
    return true;
  }, [answer, call, flow?.phase, open, target]);
  const check = useCallback(
    (ended = false) => {
      const id = live.current;
      if (!call || !id) return;
      void call({ op: "check", flowId: id, ...(ended ? { ended: true } : {}) })
        .then((reply) => answer(reply, id))
        .catch(() => undefined);
    },
    [answer, call],
  );
  const cancel = useCallback(() => {
    const id = live.current;
    if (!call || !id) return;
    void call({ op: "cancel", flowId: id })
      .then((reply) => answer(reply, id))
      .catch(() => undefined);
  }, [answer, call]);
  const clear = useCallback(() => {
    live.current = undefined;
    setFlow(undefined);
  }, []);
  const waiting = flow?.phase === "waiting";
  useEffect(() => {
    if (!waiting) return undefined;
    const timer = setInterval(() => check(), LOGIN_FLOW_CHECK_MS);
    const focused = () => check();
    window.addEventListener("focus", focused);
    return () => {
      clearInterval(timer);
      window.removeEventListener("focus", focused);
    };
  }, [check, waiting]);
  return { flow, begin, check, cancel, clear };
}
