/// Whether an Archive's completion closes the chat's tab. Only the archived chat's own completion
/// does: the client still has it selected, or it left it on its own because it left the list
/// (`fellBackFrom`). A chat selected before the archive answered (a switch while it was out, or
/// one the client already selected while a snapshot hold still showed the archived chat) keeps
/// its tab.
export interface ArchiveCloseClient {
  readonly selectedSession: string | undefined;
  fellBackFrom(sessionId: string | undefined): boolean;
}

export function archiveClosesTab(client: ArchiveCloseClient, archived: string | undefined): boolean {
  if (archived === undefined) return false;
  return client.selectedSession === archived || client.fellBackFrom(archived);
}
