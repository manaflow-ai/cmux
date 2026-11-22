/** Place a completed fork without replacing its parent; a refused host open selects and focuses it. */
export async function openFork(
  session: string | undefined,
  parent: string | undefined,
  placement: unknown,
  host: {
    open(session: string, placement: string): Promise<boolean>;
    selected(): string | undefined;
    select(session: string): Promise<string | undefined>;
    persist(session?: string): Promise<unknown>;
    focus(): void;
  },
): Promise<string | undefined> {
  if (!session) return session;
  // The native destination parser owns the default. Hand-offs can still explicitly request a tab.
  if (await host.open(session, typeof placement === "string" ? placement : "default")) return session;
  if (host.selected() !== parent) return session;
  const selected = await host.select(session);
  await host.persist(selected);
  if (selected && host.selected() === selected) host.focus();
  return selected;
}

/// Asks the app host to open chat `session` (a fork, a started Continue In…) in a tab of its own at
/// `placement` (AgentForkDestination: right, left, up, down, columnRight, columnLeft, row, tab,
/// workspace, window); false when the host opens none. Every placement opens the same way: the
/// forking page hands this chat's tail over first (tailCache.ts; a fork's own rows went over with its
/// fork reply, forkTail.ts), and its `chat.tail` reaches the host before `chat.openTab`, so the new
/// tab, wherever it opens, draws the fork on the frame it shows.
export function openInOwnTab(
  client: { handOverCurrentTail(): void },
  callNative: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  session: string,
  placement?: string,
): Promise<boolean> {
  // The new tab draws this chat from the host's tail, and this page keeps it selected, so nothing
  // else hands it over (tailCache.ts).
  client.handOverCurrentTail();
  return callNative("chat.openTab", { sessionId: session, placement: placement ?? "tab" }).then(
    () => true,
    () => false,
  );
}
