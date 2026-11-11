/// The first 13 characters of a session id (an acpmux UUIDv7's time part), enough to tell chats apart.
export function shortSession(session: string): string {
  return session.length > 13 ? session.slice(0, 13) : session;
}
