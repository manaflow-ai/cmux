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
