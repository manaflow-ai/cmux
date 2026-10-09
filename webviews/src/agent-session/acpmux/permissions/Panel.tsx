import React, { useEffect, useId, useRef, useState } from "react";
import { useT, type StringKey } from "../i18n";
import { SHORTCUT_ACTIONS, useShortcut } from "../shortcuts";
import { AgentMark } from "../../shared/AgentMark";
import { agentName } from "../agents";
import { Icon } from "../icons/Icon";
import { RequestRows, ShortcutHint, requestDetails } from "./RequestRows";
import type { PermissionClientState, PermissionDecision } from "./protocol";

const choices: Record<PermissionDecision, StringKey> = {
  allow_once: "permission.allowOnce",
  allow_chat: "permission.allowChat",
  deny: "permission.deny",
};

type Props = {
  state: PermissionClientState;
  agent?: string;
  cwd?: string;
  onRespond(groupId: string, revision: number, decision: PermissionDecision): void;
  onRetry(): void;
  onRevoke(): void;
  onRefresh(): void;
};

export function PermissionPanel({ state, agent, cwd, onRespond, onRetry, onRevoke, onRefresh }: Props) {
  const t = useT();
  const scopeId = useId();
  const [shortcutHints, setShortcutHints] = useState(false);
  useEffect(() => {
    const update = (event: KeyboardEvent) => setShortcutHints(event.altKey && event.metaKey);
    const clear = () => setShortcutHints(false);
    window.addEventListener("keydown", update);
    window.addEventListener("keyup", update);
    window.addEventListener("blur", clear);
    document.addEventListener("visibilitychange", clear);
    return () => {
      window.removeEventListener("keydown", update);
      window.removeEventListener("keyup", update);
      window.removeEventListener("blur", clear);
      document.removeEventListener("visibilitychange", clear);
    };
  }, []);
  const shortcuts = {
    allow_once: useShortcut(SHORTCUT_ACTIONS.permissionAllowOnce),
    allow_chat: useShortcut(SHORTCUT_ACTIONS.permissionAllowChat),
    deny: useShortcut(SHORTCUT_ACTIONS.permissionDeny),
  } satisfies Record<PermissionDecision, string | undefined>;
  const retryShortcut = useShortcut(SHORTCUT_ACTIONS.permissionRetry);
  const revokeShortcut = useShortcut(SHORTCUT_ACTIONS.permissionRevoke);
  const refreshShortcut = useShortcut(SHORTCUT_ACTIONS.permissionRefresh);
  const expandShortcut = useShortcut(SHORTCUT_ACTIONS.permissionExpand);
  const [expandSignal, setExpandSignal] = useState(0);
  const pendingRef = useRef<typeof state.groups>([]);
  const stateRef = useRef(state);
  stateRef.current = state;
  pendingRef.current = state.groups.filter((group) => group.state === "pending" || group.state === "collecting");
  const callbacks = useRef({ onRespond, onRetry, onRevoke, onRefresh });
  callbacks.current = { onRespond, onRetry, onRevoke, onRefresh };
  useEffect(() => {
    const handlers = new Map<string, EventListener>([
      ["permissionAllowOnce", () => respondToPending("allow_once")],
      ["permissionAllowChat", () => respondToPending("allow_chat")],
      ["permissionDeny", () => respondToPending("deny")],
      ["permissionRetry", runRetry],
      ["permissionRevoke", runRevoke],
      ["permissionRefresh", runRefresh],
      ["permissionExpand", () => setExpandSignal((value) => value + 1)],
    ]);
    function respondToPending(decision: PermissionDecision) {
      const current = stateRef.current;
      if (!current.supported || current.busy || current.loading || current.ready === false || current.uncertain) return;
      const group = pendingRef.current.find(
        (candidate) => candidate.state === "pending" && candidate.decisions.includes(decision),
      );
      if (group) callbacks.current.onRespond(group.groupId, group.revision, decision);
    }
    function runRetry() {
      const current = stateRef.current;
      if (current.supported && current.uncertain && !current.busy && !current.loading) callbacks.current.onRetry();
    }
    function runRevoke() {
      const current = stateRef.current;
      if (current.supported && current.chatAllowance && !current.busy && !current.loading && !current.uncertain)
        callbacks.current.onRevoke();
    }
    function runRefresh() {
      const current = stateRef.current;
      if (current.supported && !!current.error && !current.busy && !current.loading) callbacks.current.onRefresh();
    }
    for (const [name, handler] of handlers) window.addEventListener(`cmux-acpmux-${name}`, handler);
    return () => {
      for (const [name, handler] of handlers) window.removeEventListener(`cmux-acpmux-${name}`, handler);
    };
  }, []);
  if (!state.supported) return null;
  const pending = state.groups.filter((group) => group.state === "pending" || group.state === "collecting");
  const receipt = pending.length === 0 ? state.groups.at(-1) : undefined;
  if (!pending.length && !receipt && !state.chatAllowance && !state.error) return null;
  const disabled = state.busy || state.loading || state.ready === false || !!state.uncertain;
  const agentLabel = agent ? agentName(agent) : t("trust.agent");
  const quietButton =
    "inline-flex items-center justify-center rounded-md border-0 bg-transparent px-2 py-1.5 font-sans text-body text-muted hover:bg-hover hover:text-fg focus-visible:outline focus-visible:outline-1 focus-visible:outline-fg disabled:opacity-50";
  return (
    <section
      className="acpmux-permission acpmux-permission-panel group/permission flex max-h-[45%] shrink-0 flex-col gap-2 overflow-auto pb-2.5 text-body text-fg"
      aria-label={t("permission.title")}
      aria-busy={state.busy}
      data-shortcut-hints={shortcutHints}
    >
      {state.chatAllowance && (
        <div className="flex items-center justify-between gap-2 text-caption text-muted">
          <span>{t("permission.chatAllowed")}</span>
          <button className={quietButton} disabled={disabled} onClick={onRevoke}>
            {t("permission.revoke")}
            <ShortcutHint shortcut={revokeShortcut} />
          </button>
        </div>
      )}
      {pending.map((group) => {
        const first = group.items[0] && requestDetails(group.items[0], cwd);
        const title =
          group.items.length === 1 && first
            ? t(first.kind === "execute" ? "permission.askRun" : "permission.askTool", {
                tool: first.title ?? t("permission.toolRequest"),
              })
            : t("permission.requestsFrom", { n: group.items.length, agent: agentLabel });
        return (
          <div
            className="acpmux-permission-surface min-w-0 rounded-2xl border-[0.5px] border-solid border-edge bg-menu p-3"
            key={group.groupId}
          >
            <header className="flex flex-wrap items-start justify-between gap-x-3 gap-y-2">
              <div className="flex min-w-0 flex-1 basis-56 items-start gap-2.5">
                <span className="mt-0.5 flex size-6 shrink-0 items-center justify-center text-muted">
                  <AgentMark agent={agent} size={20} />
                </span>
                <div className="min-w-0">
                  <h3 className="m-0 line-clamp-2 break-words text-title font-semibold">{title}</h3>
                  <p className="m-0 mt-1 text-caption text-muted">
                    {group.items.length === 1 ? agentLabel : t("permission.count.other", { n: group.items.length })}
                  </p>
                </div>
              </div>
              <span
                title={t("permission.coverageDetail")}
                aria-label={t("permission.coverage")}
                aria-description={t("permission.coverageDetail")}
                className="inline-flex shrink-0 items-center gap-1 rounded-md bg-base px-1.5 py-1 text-caption text-(--agent-warning) focus-visible:outline focus-visible:outline-1 focus-visible:outline-fg"
              >
                <Icon name="security.insecure" size={12} />
                {t("permission.isolationUnverified")}
              </span>
            </header>
            <RequestRows group={group} expandSignal={expandSignal} expandShortcut={expandShortcut} cwd={cwd} />
            {group.state === "collecting" ? (
              <output className="mt-3 flex items-center gap-2 text-caption text-muted">
                <Icon name="status.inprogress" size={14} />
                {t("permission.collecting")}
              </output>
            ) : (
              <>
                {!group.decisions.includes("allow_once") && (
                  <p className="mb-0 mt-3 text-caption text-muted">{t("permission.denyOnly")}</p>
                )}
                <div className="acpmux-permission-buttons mt-3 flex flex-wrap items-center gap-2">
                  {(["allow_once", "allow_chat", "deny"] as const)
                    .filter((decision) => group.decisions.includes(decision))
                    .map((decision) => (
                      <button
                        key={decision}
                        type="button"
                        className={`inline-flex min-h-8 items-center justify-center rounded-lg border-0 px-3 py-2 font-sans text-body focus-visible:outline focus-visible:outline-1 focus-visible:outline-offset-2 focus-visible:outline-fg disabled:cursor-default disabled:opacity-50 ${decision === "allow_once" ? "bg-fg text-(--acpmux-base) font-medium" : decision === "allow_chat" ? "bg-hover text-fg" : "bg-transparent text-muted hover:bg-hover hover:text-fg"}`}
                        title={decision === "allow_chat" ? t("permission.chatScope") : undefined}
                        aria-describedby={decision === "allow_chat" ? scopeId : undefined}
                        disabled={disabled}
                        onClick={() => onRespond(group.groupId, group.revision, decision)}
                      >
                        {t(choices[decision])}
                        <ShortcutHint shortcut={shortcuts[decision]} />
                      </button>
                    ))}
                </div>
              </>
            )}
          </div>
        );
      })}
      <span className="sr-only" id={scopeId}>
        {t("permission.chatScope")}
      </span>
      {receipt && (
        <details className="acpmux-permission-receipt text-caption text-muted">
          <summary className="cursor-pointer">
            {receipt.state === "cancelled"
              ? t("permission.cancelled")
              : receipt.decision
                ? t(choices[receipt.decision])
                : t("permission.answered")}
          </summary>
          <RequestRows group={receipt} expandSignal={expandSignal} cwd={cwd} />
        </details>
      )}
      {state.error && (
        <div className="flex items-center justify-between gap-2 text-caption text-fg" role="alert">
          <span>{state.error}</span>
          <button
            className={quietButton}
            disabled={state.busy || state.loading}
            onClick={state.uncertain ? onRetry : onRefresh}
          >
            {state.uncertain ? t("permission.checkRetry") : t("permission.refresh")}
            <ShortcutHint shortcut={state.uncertain ? retryShortcut : refreshShortcut} />
          </button>
        </div>
      )}
    </section>
  );
}
