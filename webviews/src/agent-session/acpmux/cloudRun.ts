/// Cloud as where a new chat runs (Labs, leo-workspace design/cloud-work-mode.md): the environment
/// picker's Cloud row (EnvironmentPicker `runMode` "cloud") makes the chat's first send a
/// `cloud.startChat` to the host (AgentPaneCloudStart). The host takes a Cloud machine sized for
/// the chat, copies the chat's folder there and opens the chat there with this prompt; this tab,
/// which never started a chat, then closes. Nothing asks for a machine, a size or an environment.
/// The host shows the progress and any failure as its own toast, and the chat shows them under the
/// message (CloudStartView, cloudStartProgress.ts); the prompt stays in the composer until the chat
/// opens on the machine.

import { isAgentHome } from "./sessionList";
import { pickFolder } from "./startFolderModel";
import type { ComposerAttachment } from "./attachments";

/// What the page hands the host. `home`: the chat has no project folder on this Mac, so nothing is
/// copied and the chat starts in the machine's own home folder (cloudStartFolder).
export type CloudStart = {
  task: string;
  attachments?: ComposerAttachment[];
  cwd?: string;
  home?: boolean;
  harness?: string;
  model?: string;
  /** The permission mode picked before the first send (cloudModePick.ts); none: the machine's own start mode. */
  mode?: string;
  environment?: string;
  reservationKey?: string;
  /** A native gesture ticket reserved before waiting for a Cloud machine lease. */
  gestureTicket?: string;
  /** The send again after `cloud.signIn` signed in: the host's kept click authorizes it (cloudSignIn.ts startAfterSignIn). */
  signedIn?: true;
  /** The plan card's Switch to <team>: the host switches to this team (as the team picker does), then starts. */
  team?: string;
};

/// Which folder a Cloud chat starts in: the chat's project on this Mac, copied to the machine, when
/// it has one; else the machine's home folder, with nothing copied (a chat in no project, or one
/// whose folder is home or above it, which is never copied). Leo, 2026-10-31: "whenever i start a
/// chat it should be able to send me to cloud autommatically".
export function cloudStartFolder(project: string | undefined): { cwd: string } | { home: true } {
  const folder = project?.replace(/\/+$/, "");
  // `/`, `/Users`, a home folder: never copied (NewTabScreen's homeOrAbove, CloudMoveFolder isTooBroad).
  if (!folder?.startsWith("/") || /^(?:\/(?:Users|home)(?:\/[^/]+)?)?$/.test(folder)) return { home: true };
  // A no-project chat's private agent-home folder (sessionList.ts isAgentHome) is no project either:
  // never copied.
  if (isAgentHome(folder)) return { home: true };
  return { cwd: folder };
}

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/// The New Tab page's project pick goes to the host on its click (workspace.useFolder), so a Cloud
/// send copies it (#29789): cloud.startChat copies only the pane's own folders. It is attached
/// whenever Cloud may be offered to this new chat (`offerable`), not only once the host answered
/// what the tab already sent (`sandbox.checked`): a pick made while that check was out was never
/// sent, and the Cloud start then failed with pathOutsideRoots. A project folder granted to a tab
/// the check then hands to a run is harmless. Only a folder Cloud would copy (cloudStartFolder);
/// a home or root answer asks nothing here (the local start still asks on Return).
/// `granted` gets the folder and its grant's promise, so a Cloud send of that folder made right
/// after the pick waits for it instead of racing it (cloudFolderGrants).
export function newTabProjectPick(
  callNative: Native,
  offerable: boolean,
  granted?: (cwd: string, grant: Promise<unknown>) => void,
): { onProjectPicked?: (cwd: string) => void } {
  if (!offerable) return {};
  return {
    onProjectPicked: (cwd) => {
      if (!("cwd" in cloudStartFolder(cwd))) return;
      const grant = pickFolder(callNative, cwd, () => undefined);
      granted?.(cwd, grant);
    },
  };
}

/// How long a Cloud send waits for its folder's grant (workspace.useFolder) before it goes anyway.
/// A grant that never answers must not hold the composer forever: past this the start goes, and a
/// folder still not granted gets the host's worded "pick the folder" refusal (#34406), with the
/// prompt still in the composer.
export const CLOUD_FOLDER_GRANT_WAIT_MS = 3000;

/// The folder grants the page's Cloud picks made (the composer's Cloud row, the New Tab project
/// pick), by folder as cloudStartFolder spells it. A Cloud start waits for the grant of the folder it
/// sends, never another pick's, and at most `waitMs`. A grant leaves once it settles.
export function cloudFolderGrants(waitMs: number = CLOUD_FOLDER_GRANT_WAIT_MS) {
  const grants = new Map<string, Promise<unknown>>();
  return {
    /// A grant of `cwd` is out. A folder Cloud never copies is never sent, so nothing waits for it.
    granting(cwd: string, grant: Promise<unknown>): void {
      const folder = cloudStartFolder(cwd);
      if (!("cwd" in folder)) return;
      grants.set(folder.cwd, grant);
      const leave = () => {
        if (grants.get(folder.cwd) === grant) grants.delete(folder.cwd);
      };
      grant.then(leave, leave);
    },
    /// Settles once the grant of `cwd` settles (either way), or after `waitMs`; at once with none.
    /// The timer is cleared when the grant wins, so nothing is left running.
    settled(cwd: string | undefined): Promise<void> {
      const grant = cwd ? grants.get(cwd) : undefined;
      if (!grant) return Promise.resolve();
      return new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, waitMs);
        const done = () => {
          clearTimeout(timer);
          resolve();
        };
        grant.then(done, done);
      });
    },
  };
}

export type CloudFolderGrants = ReturnType<typeof cloudFolderGrants>;

/// The pane's Cloud start (App.tsx `startCloud`): one at a time (oneCloudStart), and the host call
/// goes once the grant of the folder it sends has settled or the wait ran out (cloudFolderGrants).
export function grantedCloudStart(
  callNative: (method: string, params?: Record<string, unknown>) => Promise<unknown>,
  grants: CloudFolderGrants,
): (start: CloudStart, key?: string) => Promise<CloudStartAnswer> | undefined {
  return oneCloudStart((method, params) =>
    grants.settled(typeof params.cwd === "string" ? params.cwd : undefined).then(() => callNative(method, params)),
  );
}

/// The host's answer: ok, or a code with the host's own words when it has them.
/// `retryable`: another try of the same start can help (the machine didn't connect, a copy timed out), so the card offers Retry.
export type CloudStartAnswer =
  | { ok: true }
  | { ok: false; code: string; message?: string; retryable?: boolean; details?: unknown };

/// Keeps the failed first-send prompt in the composer while Cloud account sign-in runs, then
/// resumes it once. Concurrent clicks share one browser callback, and a later click after a
/// successful callback cannot send the prompt a second time.
export type CloudSignInRetry = (() => Promise<boolean>) & { reset: () => void };

export function makeCloudSignInRetry(resume: () => Promise<CloudStartAnswer> | undefined): CloudSignInRetry {
  let inFlight: Promise<boolean> | undefined;
  let resumed = false;
  // A reset (another card) makes an older retry's late answer count for nothing.
  let epoch = 0;
  const retry = (() => {
    if (resumed) return Promise.resolve(false);
    if (inFlight) return inFlight;
    const started = resume();
    if (!started) return Promise.resolve(false);
    const mine = epoch;
    const attempt = started
      .then((answer) => {
        if (mine !== epoch || !answer.ok || resumed) return false;
        resumed = true;
        return true;
      })
      .catch(() => false)
      .finally(() => {
        if (inFlight === attempt) inFlight = undefined;
      });
    inFlight = attempt;
    return attempt;
  }) as CloudSignInRetry;
  retry.reset = () => {
    epoch += 1;
    inFlight = undefined;
    resumed = false;
  };
  return retry;
}

/// A page-side refusal before anything goes to the host: Cloud is picked but not offered now
/// (a chat is starting here). Attachment contents go with the prompt; the native host checks them
/// before provisioning and uploads them before opening the chat. A refused prompt stays in the composer.
export function cloudPageRefusal(offered: boolean): "cloud_not_now" | undefined {
  return offered ? undefined : "cloud_not_now";
}

/// Whether the composer's agent runs on this Mac, given that the chat itself is this Mac's
/// (`chatLocal`): a new chat with Cloud picked runs its agent on the Cloud machine, whose sign-in the
/// start handles (the login copy, or the machine's own sign-in). This Mac's harness health and sign-in
/// then neither show nor hold Send: a Mac with no agent CLI signed in, whose composer then names a
/// built-in such as UniiChat, kept every Cloud send under "unii isn't signed in", for a harness the
/// start never runs (Cloud composer journey, run 42953585969).
export function composerAgentLocal(chatLocal: boolean, runMode: string | undefined, sessionId?: string | null) {
  return chatLocal && !(runMode === "cloud" && !sessionId);
}

/// Sends `start` to the host and resolves to its answer; never rejects. The host answers once the
/// chat opens on the machine (a new machine boots in minutes), or with why it didn't.
export async function startCloudChat(
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  start: CloudStart,
  key: string = crypto.randomUUID(),
): Promise<CloudStartAnswer> {
  const params: Record<string, unknown> = { task: start.task, key };
  if (start.attachments?.length) params.attachments = start.attachments;
  if (start.cwd) params.cwd = start.cwd;
  else if (start.home) params.home = true;
  if (start.harness) params.harness = start.harness;
  if (start.model) params.model = start.model;
  // The mode picked for this start (cloudModePick.ts); the host starts the chat in it on the
  // person's own machine (AgentPaneCloudStart `mode`).
  if (start.mode) params.mode = start.mode;
  if (start.environment) params.environment = start.environment;
  if (start.reservationKey) params.reservationKey = start.reservationKey;
  if (start.gestureTicket) params.gestureTicket = start.gestureTicket;
  if (start.signedIn) params.signedIn = true;
  if (start.team) params.team = start.team;
  try {
    await call("cloud.startChat", params);
    return { ok: true };
  } catch (error) {
    const { code, message, userMessage, retryable, details } = (error ?? {}) as {
      code?: unknown;
      message?: unknown;
      userMessage?: unknown;
      retryable?: unknown;
      details?: unknown;
    };
    const words = typeof userMessage === "string" ? userMessage : typeof message === "string" ? message : undefined;
    return {
      ok: false,
      code: typeof code === "string" && code ? code : "unavailable",
      ...(words ? { message: words } : {}),
      ...(retryable === true ? { retryable: true } : {}),
      ...(details !== undefined && details !== null ? { details } : {}),
    };
  }
}

/// One start at a time from a page: while one waits on the host (a new machine boots in minutes),
/// another Return starts nothing and says nothing, instead of a second start the host refuses.
export function oneCloudStart(
  call: (method: string, params: Record<string, unknown>) => Promise<unknown>,
): (start: CloudStart, key?: string) => Promise<CloudStartAnswer> | undefined {
  let waiting = false;
  return (start, key) => {
    if (waiting) return undefined;
    waiting = true;
    return startCloudChat(call, start, key).finally(() => {
      waiting = false;
    });
  };
}

/// Where a Cloud start's key is kept between sends: the page's `localStorage`. The agent panes share
/// one in-memory web data store (AgentPaneView+Warmup), so it outlives a page reload or a closed tab
/// but not an app relaunch.
export type CloudStartKeyStore = {
  getItem(name: string): string | null;
  setItem(name: string, value: string): void;
};

const CLOUD_START_KEYS = "cmux.cloudStart.keys";
/// A kept key older than this is a new send: the host's ledger has long settled that start.
const CLOUD_START_KEY_TTL_MS = 24 * 60 * 60 * 1000;

/// What makes two sends the same start: the prompt, its chips (by id, name and size, never their
/// bytes), the folder, the agent, the model and the environment. An edited prompt is a new start, and so
/// is a send in another team (the plan card's Switch to <team>): the first team's ledger entry is not its.
export function cloudStartFingerprint(start: CloudStart): string {
  const chips = (start.attachments ?? []).map((chip) => [chip.id, chip.kind, chip.name, chip.size]);
  const text = JSON.stringify([
    start.task,
    chips,
    start.cwd ?? null,
    start.home === true,
    start.harness ?? null,
    start.model ?? null,
    start.environment ?? null,
    // Only a send that switches team names it, so every other start keeps the key it had.
    ...(start.team ? [start.team] : []),
    // A start in another mode is another start; one with no pick keeps the key it had.
    ...(start.mode ? [`mode:${start.mode}`] : []),
  ]);
  // FNV-1a, two 32-bit lanes: a short stable name for the entry, never the prompt itself.
  let a = 0x811c9dc5;
  let b = 0x01000193;
  for (let index = 0; index < text.length; index++) {
    const code = text.charCodeAt(index);
    a = Math.imul(a ^ code, 0x01000193) >>> 0;
    b = Math.imul(b ^ code, 0x811c9dc5) >>> 0;
  }
  return `${a.toString(16).padStart(8, "0")}${b.toString(16).padStart(8, "0")}`;
}

/// The page's store, or none (a page with no `localStorage`, or one that throws): keys then live
/// only as long as the page.
function pageKeyStore(): CloudStartKeyStore | undefined {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

/// One key per start the person asked for (#33493). A retry of a start whose answer was lost or
/// failed (the same prompt sent again from the composer, also after a page reload) reuses its first
/// key, so the host's ledger (cmux-tui `link/start_chat_cli.rs`, keyed by it) reaches the machine
/// that start made or is making instead of creating a second one. The key is forgotten once the
/// start opened its chat, or the cap card sent the prompt here instead; a changed prompt, folder,
/// agent, model or environment is a new start with a new key.
export function cloudStartKeys(
  store: CloudStartKeyStore | undefined = pageKeyStore(),
  now: () => number = Date.now,
  newKey: () => string = () => crypto.randomUUID(),
) {
  type Kept = Record<string, { key: string; at: number }>;
  const read = (): Kept => {
    if (!store) return {};
    try {
      const value = JSON.parse(store.getItem(CLOUD_START_KEYS) ?? "{}") as unknown;
      return value && typeof value === "object" && !Array.isArray(value) ? (value as Kept) : {};
    } catch {
      return {};
    }
  };
  const write = (kept: Kept) => {
    if (!store) return;
    try {
      store.setItem(CLOUD_START_KEYS, JSON.stringify(kept));
    } catch {
      // A full or refused store keeps nothing: the key still holds for this page's retries below.
    }
  };
  // This page's own keys, so a store that refuses writes still dedupes the retries made here.
  const local: Kept = {};
  const fresh = (entry: { key: string; at: number } | undefined, at: number) =>
    entry && typeof entry.key === "string" && typeof entry.at === "number" && at - entry.at < CLOUD_START_KEY_TTL_MS
      ? entry
      : undefined;
  return {
    /// The key for `start`: the kept one while its start has not opened a chat, else a new one, kept.
    keyFor(start: CloudStart): string {
      const at = now();
      const name = cloudStartFingerprint(start);
      const kept = read();
      const found = fresh(kept[name], at) ?? fresh(local[name], at);
      const key = found?.key ?? newKey();
      for (const [other, entry] of Object.entries(kept)) if (!fresh(entry, at)) delete kept[other];
      kept[name] = { key, at: found?.at ?? at };
      local[name] = kept[name];
      write(kept);
      return key;
    },
    /// The start sent with `start` ended in `answer`: one that opened its chat, or whose prompt goes
    /// to a chat on this Mac, is done, and the next send of the same prompt is a new start. A failure
    /// keeps the key: the start may have made its machine, and the retry must reach it.
    ended(start: CloudStart, answer: CloudStartAnswer) {
      if (!answer.ok && !cloudRunsHere(answer)) return;
      const name = cloudStartFingerprint(start);
      const kept = read();
      delete kept[name];
      delete local[name];
      write(kept);
    },
  };
}

/// The team a Cloud send switches to (the plan card's Switch to <team>). It stays with the start it
/// began, so the card's Retry of that start names the team too and reaches the same start key (its
/// machine and copy); it goes once that start ends in a chat (or on this Mac), or the person leaves
/// Cloud or the chat (`reset`).
export function cloudStartTeam() {
  let team: string | undefined;
  return {
    pick(id: string) {
      team = id;
    },
    forSend(): string | undefined {
      return team;
    },
    ended(answer: CloudStartAnswer) {
      if (answer.ok || cloudRunsHere(answer)) team = undefined;
    },
    reset() {
      team = undefined;
    },
  };
}

/// A failure the card already says in the host's words (with Retry when another try can help, or the
/// sign-in's own reason), so the page says nothing more.
export function cloudStartSaid(answer: CloudStartAnswer): boolean {
  return (
    !answer.ok &&
    ["cloud_start_failed", "cloud_plan_required", "cloud_chat_already_started", "cloud_prompt_changed"].includes(
      answer.code,
    )
  );
}

/// The host's card at the plan's machine cap answered Run on This Mac (CloudMachineCap.runHereCode): no machine was
/// made, and the page sends the kept prompt to a chat on this Mac instead.
export function cloudRunsHere(answer: CloudStartAnswer): boolean {
  return !answer.ok && answer.code === "run_on_this_mac";
}
