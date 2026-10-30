/// Whether an Archive's completion closes the chat's tab. Only the archived chat's own completion
/// does: the tab still shows it (nothing selected since, or it is still the selection), or the
/// client left it on its own because it left the list (`fellBackFrom`). A chat the person selected
/// while the archive was in flight keeps its tab.
export interface ArchiveCloseClient {
  readonly selectionToken: number;
  readonly selectedSession: string | undefined;
  fellBackFrom(sessionId: string | undefined): boolean;
}

export function archiveClosesTab(client: ArchiveCloseClient, archived: string | undefined, selection: number): boolean {
  if (archived === undefined) return false;
  return (
    client.selectionToken === selection || client.selectedSession === archived || client.fellBackFrom(archived)
  );
}
