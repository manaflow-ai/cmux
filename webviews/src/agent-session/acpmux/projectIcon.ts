// Project favicons for the picker badges (`project.icon`). Not wired yet.
type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// Tests replace the host.
export function setProjectIconHost(_next: Call | undefined): void {}
