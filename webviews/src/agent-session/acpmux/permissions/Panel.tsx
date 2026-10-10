import React, { useEffect, useRef, useState } from "react";
import { useT, type StringKey } from "../i18n";
import { SHORTCUT_ACTIONS, useShortcut, withShortcut } from "../shortcuts";
import type { PermissionClientState, PermissionDecision, PermissionGroup } from "./protocol";

declare global {
  interface Window {
    /// The first pending permission request (the app reads it before its Allow confirmation).
    cmuxAcpmuxPendingPermission?: () => { groupId: string; revision: number; title: string } | null;
  }
}

const choices: Record<PermissionDecision, StringKey> = {
  allow_once: "permission.allowOnce",
  allow_chat: "permission.allowChat",
  deny: "permission.deny",
};

type Props = {
  state: PermissionClientState;
  onRespond(groupId: string, revision: number, decision: PermissionDecision): void;
  onRetry(): void;
  onRevoke(): void;
  onRefresh(): void;
};

function GroupItems({ group, expandSignal }: { group: PermissionGroup; expandSignal: number }) {
  const t = useT();
  const container = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (expandSignal === 0) return;
    container.current?.querySelectorAll("details").forEach((details) => {
      details.open = true;
    });
  }, [expandSignal]);
  return (
    <div className="acpmux-permission-items" ref={container}>
      {group.items.map((item) => {
        const rawTool = item.request.toolCall;
        const tool =
          rawTool && typeof rawTool === "object" && !Array.isArray(rawTool)
            ? (rawTool as Record<string, unknown>)
            : undefined;
        return (
          <details key={item.permissionId}>
            <summary>
              <span>{typeof tool?.title === "string" ? tool.title : t("permission.toolRequest")}</span>
              <span className="acpmux-permission-item-kind">{typeof tool?.kind === "string" ? tool.kind : ""}</span>
              {item.state !== "pending" && (
                <span>{t(item.state === "cancelled" ? "permission.itemCancelled" : "permission.itemResolved")}</span>
              )}
            </summary>
            {Array.isArray(tool?.locations) && (
              <ul>
                {tool.locations.map((location, index) => {
                  const path =
                    location && typeof location === "object" ? (location as Record<string, unknown>).path : undefined;
                  return typeof path === "string" ? <li key={index}>{path}</li> : null;
                })}
              </ul>
            )}
            {tool?.rawInput !== undefined && (
              <pre>{typeof tool.rawInput === "string" ? tool.rawInput : JSON.stringify(tool.rawInput, null, 2)}</pre>
            )}
            {tool?.content !== undefined && <pre>{JSON.stringify(tool.content, null, 2)}</pre>}
            {tool?.rawInput === undefined && tool?.content === undefined && <p>{t("permission.noInput")}</p>}
          </details>
        );
      })}
    </div>
  );
}

export function PermissionPanel({ state, onRespond, onRetry, onRevoke, onRefresh }: Props) {
  const t = useT();
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
      ["permissionAllowOnce", (event) => respondToPending("allow_once", pinnedGroup(event))],
      ["permissionAllowChat", (event) => respondToPending("allow_chat", pinnedGroup(event))],
      ["permissionDeny", () => respondToPending("deny")],
      ["permissionRetry", runRetry],
      ["permissionRevoke", runRevoke],
      ["permissionRefresh", runRefresh],
      ["permissionExpand", () => setExpandSignal((value) => value + 1)],
    ]);
    // The app's confirmation pinned one request (cx-zk9t): an allow answers only that group,
    // at the revision the person saw; a changed or answered group stays pending.
    function pinnedGroup(event: Event): { groupId: string; revision: number } | undefined {
      const detail = (event as CustomEvent<unknown>).detail;
      if (!detail || typeof detail !== "object") return undefined;
      const { groupId, revision } = detail as { groupId?: unknown; revision?: unknown };
      return typeof groupId === "string" && typeof revision === "number" ? { groupId, revision } : undefined;
    }
    function respondToPending(decision: PermissionDecision, pinned?: { groupId: string; revision: number }) {
      const current = stateRef.current;
      if (!current.supported || current.busy || current.loading || current.ready === false || current.uncertain) return;
      const group = pendingRef.current.find(
        (candidate) =>
          candidate.state === "pending" &&
          candidate.decisions.includes(decision) &&
          (!pinned || (candidate.groupId === pinned.groupId && candidate.revision === pinned.revision)),
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
    // The request an Allow shortcut would answer, for the app's confirmation to name and pin.
    window.cmuxAcpmuxPendingPermission = () => {
      const group = pendingRef.current.find((candidate) => candidate.state === "pending");
      if (!group) return null;
      const titles = group.items.map((item) => {
        const tool = item.request.toolCall;
        const title = tool && typeof tool === "object" ? (tool as Record<string, unknown>).title : undefined;
        return typeof title === "string" ? title : "";
      });
      return { groupId: group.groupId, revision: group.revision, title: titles.filter(Boolean).join(", ") };
    };
    return () => {
      for (const [name, handler] of handlers) window.removeEventListener(`cmux-acpmux-${name}`, handler);
      window.cmuxAcpmuxPendingPermission = undefined;
    };
  }, []);
  if (!state.supported) return null;
  const pending = state.groups.filter((group) => group.state === "pending" || group.state === "collecting");
  const receipt = pending.length === 0 ? state.groups.at(-1) : undefined;
  if (!pending.length && !receipt && !state.chatAllowance && !state.error) return null;
  const disabled = state.busy || state.loading || state.ready === false || !!state.uncertain;
  return (
    <section
      className="acpmux-permission acpmux-permission-panel"
      aria-label={t("permission.title")}
      aria-busy={state.busy}
    >
      <div className="acpmux-permission-coverage" title={t("permission.coverageDetail")}>
        {t("permission.coverage")}
      </div>
      {state.chatAllowance && (
        <div className="acpmux-permission-allowance">
          <span>{t("permission.chatAllowed")}</span>
          <button disabled={disabled} onClick={onRevoke}>
            {withShortcut(t("permission.revoke"), revokeShortcut)}
          </button>
        </div>
      )}
      {pending.map((group) => (
        <div className="acpmux-permission-card" key={group.groupId}>
          <strong>{t("permission.title")}</strong>
          <p className="acpmux-permission-scope">
            {t(group.items.length === 1 ? "permission.count.one" : "permission.count.other", { n: group.items.length })}
          </p>
          {group.state === "pending" && (
            <button type="button" onClick={() => setExpandSignal((value) => value + 1)}>
              {withShortcut(t("permission.expand"), expandShortcut)}
            </button>
          )}
          <GroupItems group={group} expandSignal={expandSignal} />
          {group.state === "collecting" ? (
            <output>{t("permission.collecting")}</output>
          ) : (
            <>
              {group.decisions.includes("allow_chat") && (
                <p className="acpmux-permission-scope">{t("permission.chatScope")}</p>
              )}
              {!group.decisions.includes("allow_once") && (
                <p className="acpmux-permission-scope">{t("permission.denyOnly")}</p>
              )}
              <div className="acpmux-permission-buttons">
                {group.decisions.map((decision) => (
                  <button
                    key={decision}
                    className={decision === "deny" ? "acpmux-permission-deny" : undefined}
                    disabled={disabled}
                    onClick={() => onRespond(group.groupId, group.revision, decision)}
                  >
                    {withShortcut(t(choices[decision]), shortcuts[decision])}
                  </button>
                ))}
              </div>
            </>
          )}
        </div>
      ))}
      {receipt && (
        <details className="acpmux-permission-receipt">
          <summary>
            {receipt.state === "cancelled"
              ? t("permission.cancelled")
              : receipt.decision
                ? t(choices[receipt.decision])
                : t("permission.answered")}
          </summary>
          <GroupItems group={receipt} expandSignal={expandSignal} />
        </details>
      )}
      {state.error && (
        <div className="acpmux-permission-error" role="alert">
          <span>{state.error}</span>
          <button disabled={state.busy || state.loading} onClick={state.uncertain ? onRetry : onRefresh}>
            {withShortcut(
              state.uncertain ? t("permission.checkRetry") : t("permission.refresh"),
              state.uncertain ? retryShortcut : refreshShortcut,
            )}
          </button>
        </div>
      )}
    </section>
  );
}
