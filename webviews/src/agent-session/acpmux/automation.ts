import { turnFiles } from "./diff";
import type { AcpmuxSnapshot } from "./model";
import type { PermissionDecision } from "./permissions/protocol";

// Automation verbs for the DEBUG `debug.agent_pane` socket method (window.cmuxAcpmuxDebug).
// Each verb runs the same page action a click or key runs (callNative and its
// cmuxAcpmuxActions map, selectSession, openDiff), so a scripted end-to-end check drives the
// real chat path in a window that never becomes key. None of them takes app focus.

export type AutomationHost = {
  snapshot(): AcpmuxSnapshot;
  /// The page's action path (callNative): chat.send, chat.new, chat.permission, ...
  call(method: string, params?: Record<string, unknown>): Promise<unknown>;
  /// The sidebar row's selection path.
  selectSession(sessionId: string): void;
  /// The edited-files card's "View changes" path.
  openDiff(rowId: string): void;
  /// The open changes view: whether it shows and the paths it lists.
  diff(): { open: boolean; paths: string[] };
};

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
    lastAssistant: assistant ? { text: assistant.text ?? "", streaming: assistant.streaming === true } : null,
    sessions: snapshot.sessions.map((session) => ({
      sessionId: session.sessionId,
      title: session.displayTitle ?? session.title ?? session.name ?? null,
      harness: session.harness ?? null,
      status: session.status ?? null,
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
    changedFiles: turnFiles(snapshot.rows).map((file) => file.path),
    diff: host.diff(),
  };
}

/// How long sendPrompt waits for chat.send to fail before it reports the prompt as sent.
/// chat.send settles only when the turn ends, which can be minutes or wait on an ask.
export const SEND_ACCEPT_WINDOW_MS = 1_500;

export async function sendPrompt(host: AutomationHost, text: string, acceptWindowMs = SEND_ACCEPT_WINDOW_MS) {
  if (!text.trim()) return { error: "empty prompt" };
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

export async function newChat(host: AutomationHost, harness?: string, cwd?: string) {
  await host.call("chat.new", { ...(harness ? { harness } : {}), ...(cwd ? { cwd } : {}) });
  return { sessionId: host.snapshot().sessionId ?? null };
}

export function selectSession(host: AutomationHost, sessionId: string) {
  if (!host.snapshot().sessions.some((session) => session.sessionId === sessionId)) {
    return { error: `no session ${JSON.stringify(sessionId)}` };
  }
  host.selectSession(sessionId);
  return { selected: sessionId };
}

/// Answers the pending ask the way its panel does: a grouped ask with `decision`
/// (default allow_once), a single ask with `optionId` (default its first allowing option,
/// or its first denying option when `allow` is false).
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
    : permission.options.find((candidate) => candidate.allow === allow);
  if (!option) return { error: "no matching option", options: permission.options };
  await host.call("chat.permission", { permissionId: permission.permissionId, optionId: option.id });
  return { answered: permission.permissionId, optionId: option.id };
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
