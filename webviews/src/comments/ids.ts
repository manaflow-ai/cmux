/** Returns the opaque request id used by the native diff-comments bridge. */
export function makeClientId(): string {
  return crypto.randomUUID();
}
