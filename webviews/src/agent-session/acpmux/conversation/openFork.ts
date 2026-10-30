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
