/// Where a chat runs, as the environment picker (EnvironmentPicker.tsx) lists it: this computer, an
/// SSH machine (an `ssh://` acpmux peer) or a Cloud machine (any other peer, or a Cloud chat's host).
/// The machines are the composer's computers (ComposerContext availableComputers): acpmux's peers
/// and the hosts its chats ran on. Nothing here keeps a list of its own.
export type EnvironmentKind = "local" | "ssh" | "cloud";
export type Environment = { id: string; label: string; kind: EnvironmentKind };

const SECTION_ORDER: readonly EnvironmentKind[] = ["local", "ssh", "cloud"];

/// Each peer's transport from `_acpmux/status`: `ssh` for an `ssh://` peer, `cloud` for a
/// `ws://`/`wss://` one (cmux Cloud and other daemons the user connected by URL). In the app the
/// relay keeps only `name` and `transport` (the URL's scheme; AcpmuxPaneMethods.replyShapes), so
/// `transport` comes first; the raw `url` is read only when the page talks to acpmux directly.
export function peerKindsFromStatus(status: unknown): Record<string, "ssh" | "cloud"> {
  const peers = (status as { peers?: unknown } | undefined)?.peers;
  if (!Array.isArray(peers)) return {};
  const kinds: Record<string, "ssh" | "cloud"> = {};
  for (const peer of peers) {
    const name = (peer as { name?: unknown } | null)?.name;
    if (typeof name !== "string" || !name) continue;
    const { transport, url } = peer as { transport?: unknown; url?: unknown };
    const ssh = typeof transport === "string" ? transport === "ssh" : typeof url === "string" && url.startsWith("ssh://");
    kinds[name] = ssh ? "ssh" : "cloud";
  }
  return kinds;
}

/// The environments in the order the picker lists them and ⌥⌘1–9 number them: Local, then SSH,
/// then Cloud, each in the order given.
export function orderEnvironments(environments: readonly Environment[]): Environment[] {
  return SECTION_ORDER.flatMap((kind) => environments.filter((environment) => environment.kind === kind));
}

/// The environment ⌥⌘`digit` picks, if any. The digit counts the full list, never a filtered one,
/// so a shortcut names the same machine whatever the search field holds.
export function environmentForDigit(environments: readonly Environment[], digit: number): Environment | undefined {
  if (!Number.isInteger(digit) || digit < 1 || digit > 9) return undefined;
  return orderEnvironments(environments)[digit - 1];
}

/// The digit of an ⌥⌘1–9 key event, from its physical key (Option changes `key` on a Mac).
export function environmentDigit(
  event: Pick<KeyboardEvent, "altKey" | "metaKey" | "ctrlKey" | "shiftKey" | "code">,
): number | undefined {
  if (!event.altKey || !event.metaKey || event.ctrlKey || event.shiftKey) return undefined;
  const match = /^Digit([1-9])$/.exec(event.code);
  return match ? Number(match[1]) : undefined;
}
