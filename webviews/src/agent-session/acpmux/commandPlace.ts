/// Where a composer command that starts a chat starts it (Leo, 2026-11-06: "Shared chat commands
/// can start in cloud."). The option is the CLI's own: `cmux chat --on cloud` starts a chat in
/// Cloud, and `/side --on cloud` and `/cd --on cloud` do the same from the composer. `--on here`
/// (or no `--on`) keeps the command where it ran before: where the chat runs. A Cloud start goes
/// through New Cloud Chat (`palette.newCloudChat`), whose first Send is the composer's own
/// `cloud.startChat` with the Environment chip's pick (Auto by default).

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

/// What a Cloud start started from another chat hands the chat tab it opens: the `/side` prompt
/// for its composer, and the `/cd` folder that tab opens in. The panes share one web data store
/// (cloudRun.ts CloudStartKeyStore), so the new tab's page reads it once it is ready.
export type HandedCloudStart = { prompt?: string; cwd?: string };

export type HandoffStore = {
  getItem(name: string): string | null;
  setItem(name: string, value: string): void;
  removeItem(name: string): void;
};

const HANDED_CLOUD_START = "cmux.cloudCommand.handed";
/// The new tab opens within a second or two; a handoff older than this is no one's.
export const HANDED_CLOUD_START_TTL_MS = 30_000;

export function handCloudStart(store: HandoffStore | undefined, start: HandedCloudStart, now: number): void {
  try {
    store?.setItem(HANDED_CLOUD_START, JSON.stringify({ ...start, at: now }));
  } catch {
    // No storage: the new Cloud chat opens without the prompt, and the person types it there.
  }
}

/// The handed start for a new chat's page that just got its handshake, taken once: a `/cd`
/// handoff goes to the tab that opens in its folder, a `/side` one to the tab New Cloud Chat
/// opened (`pickCloud`). Anything else, or a handoff past its time, is left or dropped.
export function takeHandedCloudStart(
  store: HandoffStore | undefined,
  page: { cwd?: string | undefined; pickCloud?: unknown },
  now: number,
): HandedCloudStart | undefined {
  let kept: { prompt?: unknown; cwd?: unknown; at?: unknown } | undefined;
  try {
    const text = store?.getItem(HANDED_CLOUD_START);
    kept = text ? JSON.parse(text) : undefined;
  } catch {
    kept = undefined;
  }
  if (!kept || typeof kept !== "object") return undefined;
  const at = typeof kept.at === "number" ? kept.at : 0;
  const drop = () => {
    try {
      store?.removeItem(HANDED_CLOUD_START);
    } catch {
      // Nothing to drop it from.
    }
  };
  if (!(now - at >= 0 && now - at <= HANDED_CLOUD_START_TTL_MS)) {
    drop();
    return undefined;
  }
  const cwd = typeof kept.cwd === "string" && kept.cwd ? kept.cwd : undefined;
  const ours = cwd !== undefined ? sameFolder(cwd, page.cwd) : page.pickCloud === true;
  if (!ours) return undefined;
  drop();
  const prompt = typeof kept.prompt === "string" && kept.prompt.trim() ? kept.prompt : undefined;
  return { ...(prompt ? { prompt } : {}), ...(cwd ? { cwd } : {}) };
}

function sameFolder(a: string, b: string | undefined): boolean {
  const bare = (path: string) => path.replace(/\/+$/, "") || "/";
  return b !== undefined && bare(a) === bare(b);
}

/// A new chat page's handshake with a handed start in it: it picks Cloud (as New Cloud Chat's
/// does) and its composer, or its New Tab page, starts with the handed prompt unless the app
/// already seeded one.
export function withHandedCloudStart<T extends { draft?: string; newTab?: unknown; pickCloud?: unknown }>(
  host: T,
  handed: HandedCloudStart | undefined,
): T {
  if (!handed) return host;
  const prompt = handed.prompt;
  const page = host.newTab;
  const pageObject = typeof page === "object" && page !== null ? (page as Record<string, unknown>) : undefined;
  const newTab =
    prompt && (page === true || pageObject)
      ? {
          ...pageObject,
          draft: typeof pageObject?.draft === "string" && pageObject.draft.trim() ? pageObject.draft : prompt,
        }
      : page;
  return {
    ...host,
    pickCloud: true,
    ...(prompt && !host.draft?.trim() ? { draft: prompt } : {}),
    ...(newTab !== undefined ? { newTab } : {}),
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

/// The folder a handshake's New Tab page opens in (`newTab.cwd`), for a page whose handshake names none.
export function newTabCwd(page: unknown): string | undefined {
  const cwd = typeof page === "object" && page !== null ? (page as { cwd?: unknown }).cwd : undefined;
  return typeof cwd === "string" && cwd ? cwd : undefined;
}
