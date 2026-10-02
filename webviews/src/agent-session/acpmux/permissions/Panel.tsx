import React from "react";
import type { PermissionClientState, PermissionDecision, PermissionGroup } from "./protocol";

const choices: Record<PermissionDecision, string> = {
  allow_once: "Allow once",
  allow_chat: "Allow for this chat",
  deny: "Deny",
};

type Props = {
  state: PermissionClientState;
  onRespond(groupId: string, revision: number, decision: PermissionDecision): void;
  onRetry(): void;
  onRevoke(): void;
  onRefresh(): void;
};

function GroupItems({ group }: { group: PermissionGroup }) {
  return (
    <div className="acpmux-permission-items">
      {group.items.map((item) => {
        const rawTool = item.request.toolCall;
        const tool =
          rawTool && typeof rawTool === "object" && !Array.isArray(rawTool)
            ? (rawTool as Record<string, unknown>)
            : undefined;
        return (
          <details key={item.permissionId}>
            <summary>
              <span>{typeof tool?.title === "string" ? tool.title : "Tool request"}</span>
              <span className="acpmux-permission-item-kind">{typeof tool?.kind === "string" ? tool.kind : ""}</span>
              {item.state !== "pending" && <span>{item.state}</span>}
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
            <pre>
              {typeof tool?.rawInput === "string"
                ? tool.rawInput
                : tool?.rawInput !== undefined
                  ? JSON.stringify(tool.rawInput, null, 2)
                  : "No additional input was provided."}
            </pre>
          </details>
        );
      })}
    </div>
  );
}

export function PermissionPanel({ state, onRespond, onRetry, onRevoke, onRefresh }: Props) {
  if (!state.supported) return null;
  const pending = state.groups.filter((group) => group.state === "pending" || group.state === "collecting");
  const receipt = pending.length === 0 ? state.groups.at(-1) : undefined;
  if (!pending.length && !receipt && !state.chatAllowance && !state.error) return null;
  const disabled = state.busy || state.loading || state.ready === false || !!state.uncertain;
  return (
    <section className="acpmux-permission acpmux-permission-panel" aria-label="Tool permissions" aria-busy={state.busy}>
      <div
        className="acpmux-permission-coverage"
        title="Only actions the agent requests through ACP are covered. Host isolation is unverified."
      >
        ACP requests only · Isolation unverified
      </div>
      {state.chatAllowance && (
        <div className="acpmux-permission-allowance">
          <span>Future eligible tool requests are allowed in this chat. Deny rules still apply.</span>
          <button disabled={disabled} onClick={onRevoke}>
            Revoke
          </button>
        </div>
      )}
      {pending.map((group) => (
        <div className="acpmux-permission-card" key={group.groupId}>
          <strong>Tool permissions</strong>
          <p className="acpmux-permission-scope">
            {group.items.length} {group.items.length === 1 ? "request" : "requests"} from this turn
          </p>
          <GroupItems group={group} />
          {group.state === "collecting" ? (
            <output>Collecting requests…</output>
          ) : (
            <>
              {group.decisions.includes("allow_chat") && (
                <p className="acpmux-permission-scope">
                  Allow for this chat also approves future eligible requests until this chat stops.
                </p>
              )}
              {!group.decisions.includes("allow_once") && (
                <p className="acpmux-permission-scope">
                  An item has no single-use approval option. This group can only be denied.
                </p>
              )}
              <div className="acpmux-permission-buttons">
                {group.decisions.map((decision) => (
                  <button
                    key={decision}
                    className={decision === "deny" ? "acpmux-permission-deny" : undefined}
                    disabled={disabled}
                    onClick={() => onRespond(group.groupId, group.revision, decision)}
                  >
                    {choices[decision]}
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
              ? "Tool requests cancelled"
              : receipt.decision
                ? choices[receipt.decision]
                : "Tool requests answered"}
          </summary>
          <GroupItems group={receipt} />
        </details>
      )}
      {state.error && (
        <div className="acpmux-permission-error" role="alert">
          <span>{state.error}</span>
          <button disabled={state.busy || state.loading} onClick={state.uncertain ? onRetry : onRefresh}>
            {state.uncertain ? "Check and retry" : "Refresh"}
          </button>
        </div>
      )}
    </section>
  );
}
