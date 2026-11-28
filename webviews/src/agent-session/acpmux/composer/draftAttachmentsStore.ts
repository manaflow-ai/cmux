import type { ComposerAttachment } from "../attachments";
import type { KeptAttachments } from "./keptAttachments";

/// acpmux's draft chips (`_acpmux/draft_get {attachments: true}` / `_acpmux/draft_set {attachments}`),
/// as the page's client installs them (`chat.readDraftAttachments`, `chat.writeDraftAttachments`).
/// Either is missing before the client connects, and on a page whose client has none.
export type DraftAttachmentActions = {
  read?: (sessionId: string) => Promise<unknown>;
  write?: (sessionId: string, attachments: ComposerAttachment[]) => Promise<unknown>;
};

export type DraftAttachmentsStoreOptions = {
  /// Subscribes to the page's action map being installed or replaced (composerDraft.ts
  /// onDraftActionsChanged); answers the unsubscribe.
  actionsChanged?: (listener: () => void) => () => void;
  /// How long a read before the client connects waits for its actions before it reads the host's.
  connectWaitMs?: number;
};

/// How long a read waits for the page's client to connect: a page reads its chat's chips as it
/// mounts, often before the client has installed its actions.
export const DRAFT_ATTACHMENTS_CONNECT_WAIT_MS = 5_000;

/// How many chats' chip contents the page keeps in memory for a write that changes stores.
const CONTENTS_KEPT = 8;
const AUTHORITY_KEY_PREFIX = "cmux.draft-attachments.authority.";
type Authority = "host" | "daemon";

function authorityKey(sessionId: string): string {
  return `${AUTHORITY_KEY_PREFIX}${encodeURIComponent(sessionId)}`;
}

function readAuthority(sessionId: string): Authority | undefined {
  try {
    const value = globalThis.localStorage?.getItem(authorityKey(sessionId));
    return value === "host" || value === "daemon" ? value : undefined;
  } catch {
    return undefined;
  }
}

function rememberAuthority(sessionId: string, authority: Authority): void {
  try {
    globalThis.localStorage?.setItem(authorityKey(sessionId), authority);
  } catch {
    // Web storage is optional in galleries and can be unavailable in a private page. The
    // process-local marker still protects the current page when persistence is unavailable.
  }
}

function forgetAuthority(sessionId: string): void {
  try {
    globalThis.localStorage?.removeItem(authorityKey(sessionId));
  } catch {
    // Web storage is optional in galleries and can be unavailable in a private page.
  }
}

/// Each chat's unsent chips, kept with the chat's session in acpmux so a restart, a session switch,
/// a reconnect, another client or a move to another machine reads the same ones (Leo: "making sure
/// they dont get lost sometimes if random state happens"). The host's store (`host`) is where they
/// lived before: an older daemon (it answers no `attachments`, or refuses the write) keeps them
/// there, and chips the host still holds for a chat acpmux holds none for move to acpmux once.
/// `actions` is read at each call: a reconnect installs a new client's actions.
export function draftAttachmentsStore(
  actions: () => DraftAttachmentActions,
  host: KeptAttachments,
  options: DraftAttachmentsStoreOptions = {},
): KeptAttachments {
  /// Chats whose last write went to the host because acpmux refused it: the host is newer for them,
  /// so the next read takes the host's and moves them to acpmux.
  const hostNewer = new Set<string>();
  /// Serialize each chat's store transitions. A late daemon rejection must not move an older write
  /// to the host after a later write has already succeeded in acpmux.
  const queues = new Map<string, Promise<void>>();
  const ordered = <T>(sessionId: string, operation: () => Promise<T>): Promise<T> => {
    const previous = queues.get(sessionId) ?? Promise.resolve();
    const next = previous.then(operation);
    const completion = next.then(
      () => undefined,
      () => undefined,
    );
    queues.set(sessionId, completion);
    return next.finally(() => {
      if (queues.get(sessionId) === completion) queues.delete(sessionId);
    });
  };
  /// Each chat's chips with their contents as last read or written: a write names a chip without
  /// the contents its store already holds, so one that goes to the other store takes them from here.
  const contents = new Map<string, ComposerAttachment[]>();
  const remember = (sessionId: string, chips: ComposerAttachment[]) => {
    const merged = chips.length ? withContents(chips, contents.get(sessionId) ?? []) : undefined;
    contents.delete(sessionId);
    if (merged) contents.set(sessionId, merged);
    // Only the most recently used chats' contents stay in memory; the stores hold the rest.
    for (const oldest of contents.keys()) {
      if (contents.size <= CONTENTS_KEPT) break;
      contents.delete(oldest);
    }
  };
  const authorityFor = (sessionId: string) =>
    readAuthority(sessionId) ?? (hostNewer.has(sessionId) ? "host" : undefined);
  const toHost = async (sessionId: string, attachments: ComposerAttachment[]) => {
    const held = contents.get(sessionId) ?? attachments;
    const result = await host.write(sessionId, held);
    // l10n-allow: an internal invariant error, not shown
    if (!holdsInlineContents(result, held)) throw new Error("host did not acknowledge attachment contents");
    hostNewer.add(sessionId);
    rememberAuthority(sessionId, "host");
    return result;
  };
  /// The page's actions, waiting a moment for its client to install them when it has not yet.
  const connected = async (): Promise<DraftAttachmentActions> => {
    const now = actions();
    if (now.read || !options.actionsChanged) return now;
    await new Promise<void>((resolve) => {
      const timer = setTimeout(done, options.connectWaitMs ?? DRAFT_ATTACHMENTS_CONNECT_WAIT_MS);
      const stop = options.actionsChanged!(() => {
        if (actions().read) done();
      });
      function done() {
        clearTimeout(timer);
        stop();
        resolve();
      }
    });
    return actions();
  };
  /// Moves the host's chips for `sessionId` into acpmux; the host then forgets them, so a chip removed
  /// later never comes back from it.
  const migrate = async (
    write: NonNullable<DraftAttachmentActions["write"]>,
    sessionId: string,
    chips: ComposerAttachment[],
  ): Promise<void> => {
    let answer: unknown;
    try {
      answer = await write(sessionId, chips);
    } catch {
      hostNewer.add(sessionId);
      rememberAuthority(sessionId, "host");
      return;
    }
    if (!holdsInlineContents(answer, chips)) {
      hostNewer.add(sessionId);
      rememberAuthority(sessionId, "host");
      return;
    }
    hostNewer.delete(sessionId);
    rememberAuthority(sessionId, "daemon");
    if (chips.length) {
      try {
        await host.write(sessionId, []);
        forgetAuthority(sessionId);
      } catch {
        // Keep the daemon marker while host cleanup is unconfirmed.
      }
    } else {
      // The successful empty host read already confirmed there is nothing to clean up.
      forgetAuthority(sessionId);
    }
  };
  const readSession = async (sessionId: string): Promise<ComposerAttachment[]> => {
    const { read, write } = await connected();
    if (!read) {
      const authority = authorityFor(sessionId);
      // l10n-allow: an internal invariant error, not shown
      if (authority === "daemon") throw new Error("acpmux is unavailable while its draft is authoritative");
      const fromHost = await host.read(sessionId);
      if (fromHost.length || !options.actionsChanged || authority === "host") return fromHost;
      // l10n-allow: an internal invariant error, not shown
      throw new Error("acpmux connection is unavailable and draft authority is unknown");
    }
    // A successful response without `attachments` is an older daemon. A rejected read is a
    // storage/link failure and must not be converted into that compatibility path.
    const answer = await read(sessionId);
    const held = (answer as { attachments?: unknown } | null | undefined)?.attachments;
    // An older daemon (or one that did not answer): the host's, as before.
    if (!Array.isArray(held)) return host.read(sessionId);
    const daemonChips = held as ComposerAttachment[];
    const authority = authorityFor(sessionId);
    const hostIsNewer = authority === "host";
    // A non-empty acpmux answer is authoritative after a reload. hostNewer is process-local, so
    // a reloaded page cannot safely tell whether a non-empty host copy is newer or stale. Only a
    // successful host fallback (persisted as `host`) permits the host to supersede acpmux.
    if (daemonChips.length && !hostIsNewer) return daemonChips;
    if (!daemonChips.length && authority === "daemon" && !hostIsNewer) return daemonChips;
    // Reaching this point means the host copy is needed to decide whether migration is required.
    // A rejected read is a storage/link failure, not an empty draft.
    const fromHost = await host.read(sessionId);
    if (!fromHost.length && !hostIsNewer) return daemonChips;
    if (write) await migrate(write, sessionId, fromHost);
    return fromHost;
  };
  return {
    async read(sessionId) {
      return ordered(sessionId, async () => {
        const chips = await readSession(sessionId);
        remember(sessionId, chips);
        return chips;
      });
    },
    async write(sessionId, attachments) {
      return ordered(sessionId, async () => {
        remember(sessionId, attachments);
        const { write } = actions();
        if (!write) return toHost(sessionId, attachments);
        // The last write went to the host: acpmux may not hold the contents of a chip named without them.
        const sent = authorityFor(sessionId) === "host" ? (contents.get(sessionId) ?? attachments) : attachments;
        try {
          const answer = (await write(sessionId, sent)) as { held?: unknown } | null | undefined;
          if (!holdsInlineContents(answer, sent)) return toHost(sessionId, attachments);
          const authority = authorityFor(sessionId);
          const hadHost = hostNewer.delete(sessionId);
          rememberAuthority(sessionId, "daemon");
          if (hadHost || authority === "host") {
            try {
              await host.write(sessionId, []);
              forgetAuthority(sessionId);
            } catch {
              // Keep the daemon marker while host cleanup is unconfirmed.
            }
          }
          return { held: Array.isArray(answer?.held) ? answer.held : [] };
        } catch {
          // An older daemon refuses a draft write without text; the host keeps them as before.
          return toHost(sessionId, attachments);
        }
      });
    },
  };
}

/// A receipt only proves inline bytes landed when it names every chip that carried them. Path-only
/// chips have no bytes for the daemon or host to acknowledge, so older stores may answer anything.
function holdsInlineContents(answer: unknown, chips: ComposerAttachment[]): boolean {
  const required = chips.filter((chip) => chip.data !== undefined || chip.text !== undefined).map((chip) => chip.id);
  if (!required.length) return true;
  const held = (answer as { held?: unknown } | null | undefined)?.held;
  return Array.isArray(held) && required.every((id) => held.includes(id));
}

/// `chips` in their order, each named without its contents taking them from the same id in `from`.
function withContents(chips: ComposerAttachment[], from: ComposerAttachment[]): ComposerAttachment[] {
  return chips.map((chip) => {
    if (chip.data !== undefined || chip.text !== undefined) return chip;
    const had = from.find((old) => old.id === chip.id);
    if (!had || (had.data === undefined && had.text === undefined)) return chip;
    return {
      ...chip,
      ...(had.data !== undefined ? { data: had.data } : {}),
      ...(had.text !== undefined ? { text: had.text } : {}),
    };
  });
}
