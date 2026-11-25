// The plan the person approved in this chat (acpmux `approvedPlan`, store.rs `ApprovedPlan`): acpmux
// keeps it once an allow on a plan approval reached the agent, and a newer approval replaces it. The
// pane shows it above the composer while the agent builds it (ApprovedPlanBand.tsx). Leo's row:
// "plan pane that stays during the build, editable plan sent back".
export type ApprovedPlan = {
  markdown: string;
  /** The person edited the plan before approving it, so this is their text, not the agent's. */
  edited: boolean;
  /** The approval it answered: a close is remembered against it, and a new approval shows again. */
  permissionId: string;
  turn?: number;
  at?: number;
};

/// The summary's `approvedPlan`, or undefined when it is missing or has no text.
export function approvedPlanOf(raw: unknown): ApprovedPlan | undefined {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return undefined;
  const value = raw as Record<string, unknown>;
  const markdown = typeof value.markdown === "string" ? value.markdown.trim() : "";
  const permissionId = typeof value.permissionId === "string" ? value.permissionId : "";
  if (!markdown || !permissionId) return undefined;
  return {
    markdown,
    edited: value.edited === true,
    permissionId,
    ...(typeof value.turn === "number" ? { turn: value.turn } : {}),
    ...(typeof value.at === "number" ? { at: value.at } : {}),
  };
}

// The plans the person closed on this device, as `chat:permissionId` (as recapDismissed.ts keeps
// recaps): a closed plan stays closed, and the next approved plan shows.
const CLOSED = "cmux.agentPane.approvedPlanClosed";
const MAX_CLOSED = 200;

function read(): string[] {
  try {
    const value: unknown = JSON.parse(globalThis.localStorage?.getItem(CLOSED) ?? "[]");
    return Array.isArray(value) ? value.filter((key): key is string => typeof key === "string") : [];
  } catch {
    return [];
  }
}

export const approvedPlanKey = (chat: string, plan: ApprovedPlan) => `${chat}:${plan.permissionId}`;

export function approvedPlanClosed(key: string): boolean {
  return read().includes(key);
}

export function rememberApprovedPlanClosed(key: string): void {
  try {
    const kept = read().filter((other) => other !== key);
    globalThis.localStorage?.setItem(CLOSED, JSON.stringify([...kept, key].slice(-MAX_CLOSED)));
  } catch {
    // Storage refused: the plan is closed in this view only.
  }
}
