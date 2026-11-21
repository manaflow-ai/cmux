/// What a Delete confirmation's dismissal (Escape, an outside click, Close) leaves of the delete in
/// flight. Before the purge is sent it drops it; once the purge is out, the deletion is no longer
/// the dialog's to cancel: its completion still closes the deleted chat's tab.
export function afterDeleteDismiss<T>(inFlight: T | undefined, purging: boolean): T | undefined {
  return purging ? inFlight : undefined;
}
