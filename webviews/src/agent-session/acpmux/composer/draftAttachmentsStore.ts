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
  const hostRead = (sessionId: string) => host.read(sessionId).catch(() => [] as ComposerAttachment[]);
  const toHost = (sessionId: string, attachments: ComposerAttachment[]) => {
    hostNewer.add(sessionId);
    return host.write(sessionId, contents.get(sessionId) ?? attachments);
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
  ) => {
    try {
      await write(sessionId, chips);
    } catch {
      return;
    }
    hostNewer.delete(sessionId);
    if (chips.length) await host.write(sessionId, []).catch(() => undefined);
  };
  const read = async (sessionId: string): Promise<ComposerAttachment[]> => {
    const { read, write } = await connected();
    if (!read) return hostRead(sessionId);
    const answer = await read(sessionId).catch(() => undefined);
    const held = (answer as { attachments?: unknown } | null | undefined)?.attachments;
    // An older daemon (or one that did not answer): the host's, as before.
    if (!Array.isArray(held)) return hostRead(sessionId);
    if (held.length && !hostNewer.has(sessionId)) return held as ComposerAttachment[];
    const fromHost = await hostRead(sessionId);
    if (!fromHost.length && !hostNewer.has(sessionId)) return held as ComposerAttachment[];
    if (write) await migrate(write, sessionId, fromHost);
    return fromHost;
  };
  return {
    async read(sessionId) {
      const chips = await read(sessionId);
      remember(sessionId, chips);
      return chips;
    },
    async write(sessionId, attachments) {
      remember(sessionId, attachments);
      const { write } = actions();
      if (!write) return toHost(sessionId, attachments);
      // The last write went to the host: acpmux may not hold the contents of a chip named without them.
      const sent = hostNewer.has(sessionId) ? (contents.get(sessionId) ?? attachments) : attachments;
      try {
        const answer = (await write(sessionId, sent)) as { held?: unknown } | null | undefined;
        if (hostNewer.delete(sessionId)) await host.write(sessionId, []).catch(() => undefined);
        return { held: Array.isArray(answer?.held) ? answer.held : [] };
      } catch {
        // An older daemon refuses a draft write without text; the host keeps them as before.
        return toHost(sessionId, attachments);
      }
    },
  };
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
