/// Where a composer command that starts a chat starts it (Leo, 2026-11-06: "Shared chat commands
/// can start in cloud."). The option is the CLI's own: `cmux chat --on cloud` starts a chat in
/// Cloud, and `/cd --on cloud` in a new chat picks its folder and Cloud, so its first Send is the
/// composer's own `cloud.startChat` with the Environment chip's pick (Auto by default). From a
/// started chat, `/side --on cloud` and `/cd --on cloud` open New Cloud Chat with the prompt or
/// folder handed to it (below), and that tab's first Send is the same Cloud start. `--on here` (or
/// no `--on`) keeps a command where it ran before: where the chat runs.

export type CommandPlace = "here" | "cloud";

/// The place a command's arguments name, and the arguments without it. `--on` goes first:
/// `/side --on cloud fix the tests`, `/cd --on=cloud ~/src` is refused only for its `~`.
/// `refused`: an `--on` the composer cannot start a chat in (a VM or a device: `cmux chat --on`
/// takes those, the composer's Where menu picks them).
export type PlacedArgs = { place?: CommandPlace; rest: string } | { refused: true; on: string };

export function commandPlace(args: string | undefined): PlacedArgs {
  const typed = args?.trim() ?? "";
  const match = /^--on(?:=(\S*)|\s+(\S+)|$)(?:\s+([\s\S]*))?$/.exec(typed);
  if (!match) return { rest: typed };
  const on = (match[1] ?? match[2] ?? "").toLowerCase();
  const rest = match[3]?.trim() ?? "";
  if (on === "here" || on === "cloud") return { place: on, rest };
  return { refused: true, on };
}

/// What a started chat's `/side --on cloud` or `/cd --on cloud` hands the New Cloud Chat tab it
/// opens: the prompt for its composer, or the folder it starts in. The page keeps it in the panes'
/// shared web data store (cloudRun.ts CloudStartKeyStore) under a one-time token, and the app hands
/// only that token to the new tab (`action.run palette.newCloudChat {handoff}`, the handshake's
/// `cloudStartHandoff`). Only the tab with the token reads it, once, within its time.
export type HandedCloudStart = { prompt?: string; cwd?: string };

export type HandoffStore = {
  getItem(name: string): string | null;
  setItem(name: string, value: string): void;
  removeItem(name: string): void;
};

const HANDED_CLOUD_START = "cmux.cloudCommand.handoff.";
/// The new tab opens within a second or two; a hand-off older than this is no one's.
export const HANDED_CLOUD_START_TTL_MS = 60_000;

/// Keeps `start` for the tab the app opens with the returned token; undefined when nothing could be
/// kept (the tab then opens without it). `token`: tests name one.
export function handCloudStart(
  store: HandoffStore | undefined,
  start: HandedCloudStart,
  now: number,
  token: string = crypto.randomUUID(),
): string | undefined {
  try {
    if (!store) return undefined;
    store.setItem(HANDED_CLOUD_START + token, JSON.stringify({ ...start, at: now }));
    return token;
  } catch {
    return undefined;
  }
}

/// Drops a hand-off whose tab did not open (the app refused New Cloud Chat).
export function dropHandedCloudStart(store: HandoffStore | undefined, token: string | undefined): void {
  if (!token) return;
  try {
    store?.removeItem(HANDED_CLOUD_START + token);
  } catch {
    // Nothing to drop it from.
  }
}

/// The hand-off `token` names, taken once: a second read, another token, or one past its time get
/// nothing.
export function takeHandedCloudStart(
  store: HandoffStore | undefined,
  token: string,
  now: number,
): HandedCloudStart | undefined {
  let kept: { prompt?: unknown; cwd?: unknown; at?: unknown } | undefined;
  try {
    const text = store?.getItem(HANDED_CLOUD_START + token);
    kept = text ? JSON.parse(text) : undefined;
  } catch {
    kept = undefined;
  }
  dropHandedCloudStart(store, token);
  if (!kept || typeof kept !== "object") return undefined;
  const at = typeof kept.at === "number" ? kept.at : Number.NaN;
  if (!(now - at >= 0 && now - at <= HANDED_CLOUD_START_TTL_MS)) return undefined;
  const prompt = typeof kept.prompt === "string" && kept.prompt.trim() ? kept.prompt : undefined;
  const cwd = typeof kept.cwd === "string" && kept.cwd.startsWith("/") ? kept.cwd : undefined;
  return { ...(prompt ? { prompt } : {}), ...(cwd ? { cwd } : {}) };
}

/// The one place a new chat page reads its hand-off: from its first handshake (never a
/// reconnect's, never a chat's that has a session), by the token the app handed it. It answers the
/// handshake as the page reads it, with Cloud picked and the prompt in its composer (or New Tab
/// field) unless the app seeded one, and the folder the page then opens in (`chooseProject`).
export function receiveHandedCloudStart<
  T extends { sessionId?: string; draft?: string; newTab?: unknown; pickCloud?: unknown; cloudStartHandoff?: unknown },
>(host: T, reconnect: boolean, store: HandoffStore | undefined, now: number): { host: T; folder?: string } {
  const token = host.cloudStartHandoff;
  if (reconnect || host.sessionId || typeof token !== "string" || !token) return { host };
  const handed = takeHandedCloudStart(store, token, now);
  if (!handed) return { host };
  const prompt = handed.prompt;
  const page = host.newTab;
  const pageObject = typeof page === "object" && page !== null ? (page as Record<string, unknown>) : undefined;
  const pageDraft = typeof pageObject?.draft === "string" && pageObject.draft.trim() ? pageObject.draft : undefined;
  const newTab =
    page === true || pageObject
      ? { ...pageObject, ...(prompt ? { draft: pageDraft ?? prompt } : {}), ...(handed.cwd ? { cwd: handed.cwd } : {}) }
      : page;
  return {
    host: {
      ...host,
      pickCloud: true,
      ...(prompt && !host.draft?.trim() ? { draft: prompt } : {}),
      ...(newTab !== undefined ? { newTab } : {}),
    },
    ...(handed.cwd ? { folder: handed.cwd } : {}),
  };
}

/// The panes' shared web data store, when this page has one.
export function handoffStore(): HandoffStore | undefined {
  try {
    return typeof window === "undefined" ? undefined : window.localStorage;
  } catch {
    return undefined;
  }
}
