import { focusedArea } from "./composerFocus";
import { sessionModels } from "./modelCatalog";
import { turnFiles, turnPathsOnly } from "./diff";
import { pathKey, type AcpmuxRow, type AcpmuxSnapshot } from "./model";
import { permissionKeys, permissionOption } from "./permissionKeys";
import type { PermissionDecision } from "./permissions/protocol";
import type { RunMode } from "./sandboxRun";

// Automation verbs for the DEBUG `debug.agent_pane` socket method (window.cmuxAcpmuxDebug).
// Each verb runs the same page action a click or key runs (callNative and its
// cmuxAcpmuxActions map, selectSession, openDiff), so a scripted end-to-end check drives the
// real chat path in a window that never becomes key. None of them takes app focus.

export type AutomationHost = {
  snapshot(): AcpmuxSnapshot;
  /// The page's action path (callNative): chat.send, chat.new, chat.permission, ...
  call(method: string, params?: Record<string, unknown>): Promise<unknown>;
  /// Settles once `call(method)` can run (the chat connected: pageAction), or rejects when it never does.
  ready?(method: string): Promise<void>;
  /// The sidebar row's selection path.
  selectSession(sessionId: string): void;
  /// The edited-files card's "View changes" path.
  openDiff(rowId: string): void;
  /// The open changes view: whether it shows and the paths it lists.
  diff(): { open: boolean; paths: string[] };
  /// The location row's folder pick (startFolder.tsx: the host takes it or asks first).
  pickFolder?(cwd: string): void;
  /// The composer itself: what Return sends, and where a new chat runs (composeSend, runMode).
  compose?: AutomationCompose;
};

/// The chat composer as a person drives it: `send` puts `text` in the prompt and sends it as Return
/// does (false: the composer kept it, e.g. a Cloud start that waits on its machine), so the place the
/// composer shows decides where it goes: this Mac, Sandboxed, or Cloud's `cloud.startChat`.
export type AutomationCompose = {
  send(text: string): Promise<boolean | undefined>;
  runMode(): RunMode | undefined;
  /// The run row's pick, as a click on it (false: the composer offers no run place now).
  setRunMode(mode: RunMode): boolean;
  /// The Cloud start this page sent (cloudStartProgress.ts), or null.
  cloudStart(): unknown;
};

/// How long an automation verb waits for the chat's own action (pageAction).
export const PAGE_ACTION_WAIT_MS = 20_000;

type PageAction = (params: Record<string, unknown>) => Promise<unknown>;

/// The chat's own action `method` (cmuxAcpmuxActions, which the page installs once its chat
/// connects to acpmux), waiting up to `waitMs` for it. Every automation verb is such an action:
/// called before the chat connects, the page's callNative would send it to the native host,
/// which has no chat verbs and refuses it with only the op's name (`cmux.agent.chat.new`). So a
/// verb sent right after the pane opens (a capture's new_chat) waits for the chat instead, and
/// one that never connects says so.
export async function pageAction(
  actions: () => Record<string, PageAction> | undefined,
  method: string,
  waitMs = PAGE_ACTION_WAIT_MS,
  pause: (ms: number) => Promise<void> = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
): Promise<PageAction> {
  const deadline = Date.now() + waitMs;
  for (;;) {
    const action = actions()?.[method];
    if (action) return action;
    if (Date.now() >= deadline)
      throw new Error(`${method}: the chat did not connect to acpmux within ${Math.round(waitMs / 1000)} s`);
    await pause(100);
  }
}

const TRANSCRIPT_ROWS = 30;
const TRANSCRIPT_CHARS = 500;

/// What a script needs to decide its next step, as plain JSON.
export function automationState(host: AutomationHost) {
  const snapshot = host.snapshot();
  const assistant = [...snapshot.rows].reverse().find((row) => row.kind === "assistant");
  const groups = snapshot.permissionGroups;
  return {
    connection: snapshot.connection,
    sessionId: snapshot.sessionId ?? null,
    harness: snapshot.summary?.harness ?? null,
    isWorking: snapshot.isWorking,
    rows: snapshot.rows.length,
    /// Whether older history remains to page in, and the oldest event seq the pane holds.
    canLoadOlder: snapshot.canLoadOlder,
    historyFrom: snapshot.historyFrom ?? null,
    /// The session the tab recorded that the daemon lacks (the pane says why: ChatUnavailableState.tsx).
    missingSession: snapshot.missingSession ?? null,
    /// Why it is not here: `deleted`, `offline` or `connecting`, and the machine when known.
    unavailable: snapshot.unavailable ?? null,
    /// The chat as the pane shows it: the last TRANSCRIPT_ROWS user and assistant rows, each cut
    /// at TRANSCRIPT_CHARS, so a live proof checks the real text, not only a row count.
    transcript: snapshot.rows
      .filter((row) => (row.kind === "user" || row.kind === "assistant") && typeof row.text === "string")
      .slice(-TRANSCRIPT_ROWS)
      .map((row) => ({ kind: row.kind, text: (row.text ?? "").slice(0, TRANSCRIPT_CHARS) })),
    lastAssistant: assistant ? { text: assistant.text ?? "", streaming: assistant.streaming === true } : null,
    /// The last prompts as the pane draws them, with their way to the agent (composer-delivery-DESIGN.md):
    /// a live proof of a send that stays "Still sending" reads it here.
    prompts: snapshot.rows
      .filter((row) => row.kind === "user")
      .slice(-TRANSCRIPT_ROWS)
      .map((row) => ({
        text: (row.text ?? "").slice(0, TRANSCRIPT_CHARS),
        pending: row.pending === true,
        delivery: row.delivery?.state ?? null,
        slow: row.delivery?.slow === true,
      })),
    queued: snapshot.queue.map((entry) => entry.prompt.slice(0, TRANSCRIPT_CHARS)),
    sessions: snapshot.sessions.map((session) => ({
      sessionId: session.sessionId,
      title: session.displayTitle ?? session.title ?? session.name ?? null,
      harness: session.harness ?? null,
      status: session.status ?? null,
      unread: session.unread === true,
    })),
    permission: snapshot.permission?.pending
      ? {
          permissionId: snapshot.permission.permissionId,
          title: snapshot.permission.title ?? null,
          options: snapshot.permission.options,
        }
      : null,
    permissionGroups: (groups?.groups ?? [])
      .filter((group) => group.state === "pending" || group.state === "collecting")
      .map((group) => ({
        groupId: group.groupId,
        revision: group.revision,
        state: group.state,
        decisions: group.decisions,
        items: group.items.length,
      })),
    /// Every file the chat's edits changed: those with counts, then those listed without (an edit
    /// with no diff, a Write whose old contents are unknown), as the edited-files card lists them:
    /// once per file (model.ts `pathKey`), as its first path names it.
    changedFiles: changedFiles(snapshot.rows),
    diff: host.diff(),
    /// What has the page's focus: composer, none, or the focused element.
    focus: focusedArea(typeof document === "undefined" ? null : document.activeElement),
  };
}

/// The chat's changed files for `changedFiles`: those with counts, then those without, each once.
function changedFiles(rows: readonly AcpmuxRow[]): string[] {
  const byKey = new Map<string, string>();
  for (const file of [...turnFiles([...rows]), ...turnPathsOnly(rows)])
    if (!byKey.has(pathKey(file))) byKey.set(pathKey(file), file.path);
  return [...byKey.values()];
}

/// `{error}` when the chat never made `method` ready (host.ready), else undefined. A verb that reports
/// itself accepted after a window (sendPrompt, newChat) waits for this first, so a chat that never
/// connected is an error, never an accepted send.
async function notReady(host: AutomationHost, method: string): Promise<{ error: string } | undefined> {
  if (!host.ready) return undefined;
  return host.ready(method).then(
    () => undefined,
    (error: unknown) => ({ error: error instanceof Error ? error.message : String(error) }),
  );
}

/// How long sendPrompt waits for chat.send to fail before it reports the prompt as sent.
/// chat.send settles only when the turn ends, which can be minutes or wait on an ask.
export const SEND_ACCEPT_WINDOW_MS = 1_500;

export async function sendPrompt(host: AutomationHost, text: string, acceptWindowMs = SEND_ACCEPT_WINDOW_MS) {
  if (!text.trim()) return { error: "empty prompt" };
  const refused = await notReady(host, "chat.send");
  if (refused) return refused;
  const turn = host.call("chat.send", { text }).then(
    () => ({ ended: true as const }),
    (error: unknown) => ({ error: error instanceof Error ? error.message : String(error) }),
  );
  const outcome = await Promise.race([
    turn,
    new Promise<{ running: true }>((resolve) => setTimeout(() => resolve({ running: true }), acceptWindowMs)),
  ]);
  if ("error" in outcome) return { error: outcome.error };
  return { sent: true, turnEnded: "ended" in outcome, sessionId: host.snapshot().sessionId ?? null };
}

/// A new chat as the agent row starts it. A start that waits (the folder's trust question) is
/// reported as pending after the accept window instead of holding the socket call.
export async function newChat(
  host: AutomationHost,
  harness?: string,
  cwd?: string,
  acceptWindowMs = SEND_ACCEPT_WINDOW_MS,
) {
  const refused = await notReady(host, "chat.new");
  if (refused) return refused;
  const started = host.call("chat.new", { ...(harness ? { harness } : {}), ...(cwd ? { cwd } : {}) }).then(
    () => ({ started: true as const }),
    (error: unknown) => ({ error: error instanceof Error ? error.message : String(error) }),
  );
  const outcome = await Promise.race([
    started,
    new Promise<{ pending: true }>((resolve) => setTimeout(() => resolve({ pending: true }), acceptWindowMs)),
  ]);
  if ("error" in outcome) return { error: outcome.error };
  return { sessionId: host.snapshot().sessionId ?? null, ...("pending" in outcome ? { pending: true } : {}) };
}

/// Sends `text` through the composer's own send, as typing it and pressing Return does (sendPrompt
/// goes to `chat.send` and so never takes a Cloud start). `{sent: false}`: the composer kept the
/// prompt, which a Cloud start does until its chat opens on the machine (read `cloudStart`).
export async function composeSend(host: AutomationHost, text: string) {
  if (!text.trim()) return { error: "empty prompt" };
  if (!host.compose) return { error: "the page has no composer" };
  const sent = await host.compose.send(text);
  if (sent === undefined) return { error: "no composer shows (the New Tab page?)" };
  return { sent, runMode: host.compose.runMode() ?? null, cloudStart: host.compose.cloudStart() ?? null };
}

const RUN_MODES: readonly RunMode[] = ["persistent", "sandboxed", "cloud"];

/// Reads, or with `mode` picks as the run row's click does, where this new chat runs.
export function runMode(host: AutomationHost, mode?: string) {
  if (!host.compose) return { error: "the page has no composer" };
  if (mode !== undefined) {
    if (!RUN_MODES.includes(mode as RunMode)) return { error: `mode must be one of ${RUN_MODES.join(", ")}` };
    if (!host.compose.setRunMode(mode as RunMode)) return { error: "the composer offers no run place now" };
  }
  return { runMode: host.compose.runMode() ?? null, cloudStart: host.compose.cloudStart() ?? null };
}

/// Picks `cwd` as the folder chip's menu does; a folder that needs the user's answer shows the
/// question above the composer (answer it with a native `click` on its button).
export function pickFolder(host: AutomationHost, cwd: string) {
  if (!cwd.startsWith("/")) return { error: "cwd must be an absolute path" };
  if (!host.pickFolder) return { error: "the page cannot pick a folder" };
  host.pickFolder(cwd);
  return { picked: cwd };
}

export function selectSession(host: AutomationHost, sessionId: string) {
  if (!host.snapshot().sessions.some((session) => session.sessionId === sessionId)) {
    return { error: `no session ${JSON.stringify(sessionId)}` };
  }
  host.selectSession(sessionId);
  return { selected: sessionId };
}

/// Answers the pending ask the way its panel does: a grouped ask with `decision`
/// (default allow_once), a single ask with `optionId` (default the option the card's y key
/// picks, or its n key when `allow` is false: once, never an "always" option, which would
/// leave a standing rule behind a scripted answer).
export async function answerPermission(
  host: AutomationHost,
  options: { optionId?: string; allow?: boolean; decision?: PermissionDecision } = {},
) {
  const snapshot = host.snapshot();
  const group = snapshot.permissionGroups?.supported
    ? snapshot.permissionGroups.groups.find((candidate) => candidate.state === "pending")
    : undefined;
  if (group) {
    const decision = options.decision ?? (options.allow === false ? "deny" : "allow_once");
    if (!group.decisions.includes(decision))
      return { error: `decision ${decision} not offered`, offered: group.decisions };
    await host.call("chat.permission_group.respond", { groupId: group.groupId, revision: group.revision, decision });
    return { answered: group.groupId, decision };
  }
  const permission = snapshot.permission?.pending ? snapshot.permission : undefined;
  if (!permission) return { error: "no pending permission" };
  const allow = options.allow !== false;
  const option = options.optionId
    ? permission.options.find((candidate) => candidate.id === options.optionId)
    : permissionOption(permission.options, permissionKeys(permission.options), allow ? "y" : "n");
  if (!option) return { error: "no matching option", options: permission.options };
  await host.call("chat.permission", { permissionId: permission.permissionId, optionId: option.id });
  return { answered: permission.permissionId, optionId: option.id };
}

/// Switches the session's model as the composer's model picker does (chat.model), and its
/// effort (chat.effort on the session's effort option) when `effort` is given.
export async function setModel(host: AutomationHost, model: string, effort?: string) {
  const snapshot = host.snapshot();
  const offered = sessionModels(snapshot.catalog, snapshot.summary);
  if (!offered.some((entry) => entry.id === model)) {
    return { error: `model ${JSON.stringify(model)} is not offered`, models: offered.map((entry) => entry.id) };
  }
  await host.call("chat.model", { modelId: model });
  if (effort) {
    const option = snapshot.summary?.configOptions?.find(
      (candidate) =>
        candidate.category === "thought_level" || candidate.id === "effort" || candidate.id === "reasoning_effort",
    );
    if (!option) return { model, error: "the session offers no effort option" };
    await host.call("chat.effort", { configId: option.id, value: effort });
  }
  return { model, effort: effort ?? null };
}

/// The models the session's harness offers, with the current one.
export function models(host: AutomationHost) {
  const snapshot = host.snapshot();
  const offered = sessionModels(snapshot.catalog, snapshot.summary);
  return {
    harness: snapshot.summary?.harness ?? null,
    current: snapshot.summary?.model ?? null,
    models: offered.map((entry) => ({ id: entry.id, name: entry.name })),
  };
}

/// Opens the changes view of the latest turn that edited files, as its "View changes" does.
export function openChanges(host: AutomationHost) {
  const rows = host.snapshot().rows;
  const edited = [...rows]
    .reverse()
    .find((row) => row.kind === "activity" && (row.items ?? []).some((item) => item.tool?.diffs?.length));
  if (!edited) return { error: "no turn with edited files" };
  host.openDiff(edited.id);
  return { opened: edited.id, files: turnFiles([edited]).map((file) => file.path) };
}
