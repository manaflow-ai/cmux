type WorkflowCardOpener = (id: string, opener?: HTMLElement) => void;
export let opener: WorkflowCardOpener | undefined;
export let sideTabOpener: WorkflowCardOpener | undefined;
export const listeners = new Set<() => void>();
export function configureWorkflowCardOpen(open: WorkflowCardOpener | undefined): void {
  if (open === opener) return;
  opener = open;
  for (const listener of listeners) listener();
}
/// Opens the same workflow in the chat's full-height side tab; absent when the Labs surface is off.
export function configureWorkflowCardSideTab(open: WorkflowCardOpener | undefined): void {
  if (open === sideTabOpener) return;
  sideTabOpener = open;
  for (const listener of listeners) listener();
}
/// Whether the preview workflow surfaces are on (App.tsx `workflowPreview`: `workflowLabs` and Settings >
/// Advanced > Labs, `labs.previewFeatures`, off by default): the Workflow ask then draws as the
/// workflow approval card (PermissionCard `WorkflowAskBody`), the card says when a usage limit holds it.
export let workflowLabs = false;
export function configureWorkflowLabs(enabled: boolean): void {
  if (enabled === workflowLabs) return;
  workflowLabs = enabled;
  for (const listener of listeners) listener();
}

/// The chat's wait at an account usage limit, as the workflow card says it: acpmux's retry waits
/// for a capacity error (hub/auto_resume.rs, `retry.reason`), and a plan window is used up
/// (`usageLimits`); a provider that is only full has no window at 100%, so it is not called a
/// usage limit. `nextAt` (unix ms) is when the chat continues by itself.
export type UsageLimitHold = { nextAt?: number };

export function usageLimitHold(
  retry: { reason?: string; nextAt?: number } | undefined,
  usageLimits: unknown,
): UsageLimitHold | undefined {
  if (retry?.reason !== "capacity") return undefined;
  const windows =
    usageLimits && typeof usageLimits === "object" ? (usageLimits as { windows?: unknown }).windows : undefined;
  const spent = Array.isArray(windows) && windows.some((window) => Number(window?.usedPercent) >= 100);
  if (!spent) return undefined;
  return retry.nextAt !== undefined ? { nextAt: retry.nextAt } : {};
}

export let limitHold: UsageLimitHold | undefined;
export function configureUsageLimitHold(hold: UsageLimitHold | undefined): void {
  if (hold?.nextAt === limitHold?.nextAt && Boolean(hold) === Boolean(limitHold)) return;
  limitHold = hold;
  for (const listener of listeners) listener();
}
