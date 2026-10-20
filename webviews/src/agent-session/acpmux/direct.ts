import type {
  AcpmuxActivity,
  AcpmuxFileDiff,
  AcpmuxPermission,
  AcpmuxSecretAsk,
  AcpmuxSessionOffer,
  AcpmuxOfferResult,
  AcpmuxBackgroundTask,
  AcpmuxCompaction,
  AcpmuxPlanEntry,
  AcpmuxRow,
  AcpmuxSnapshot,
  PromptImage,
  QueueEdit,
  QueuedPrompt,
  StartSource,
} from "./model";
import { mergeModelCatalog } from "./modelCatalog";
import { commandsFromUpdate, type SlashCommand } from "./slashCommands";
import { promptBlocks, promptText, takesAudio, type ComposerAttachment } from "./attachments";
import { hostKind, sessionEntry, text, type AcpmuxSessionEntry } from "./sessionList";
import { agentName } from "./agents";
import { FORK_OP, servesOperation } from "./operations";
import { postNative } from "./native";
import { readSummaryCheckpoint } from "./changes/turnCheckpointSource";
import { HandoffClient } from "./handoff/client";
import { PermissionGroupClient } from "./permissions/client";
import { questionFromPermission } from "./question/model";
import { isNotification, typedRequest } from "./protocol/client";
import type { SessionChanged, SessionSummary } from "./protocol/generated/types";
import { supportsPermissionGroups, type PermissionDecision } from "./permissions/protocol";
import { AcpmuxRpcError, supportsHandoff } from "./handoff/protocol";
import { sessionEnforcement } from "./handoff/review";
import type { HandoffReviewInput } from "./handoff/review";
import { acpWire, redactEndpoint, type AcpWireLog } from "./wire";
import { acpmuxPerf } from "./perf";
import { translate } from "./i18n";
import { OFFER_RESULT, offersShown } from "./offer/offersShown";
import { OfferChildren } from "./offer/offerChildren";
import { errorMessage } from "./transportErrors";
import { SessionPager, type SessionPage } from "./sessionPages";
import { isWarmableCwd } from "./warmFolders";
import { SubagentFold } from "./subagents/subagentFold";
import { WORKSPACE_CONTEXT } from "./workspaceContext";
import { BOOKMARKS_KIND, bookmarksHeard } from "./threadMinimap/bookmarks";
import { type StartMode, startModeChanged } from "./startMode";
import { sameSessionStart, sessionStartOf } from "./conversation/sessionStart";

export type AcpmuxHostConfig = {
  protocolVersion: number;
  /// `acpmux-bridge`: the app's host owns the socket and its tokens (bridgeSocket.ts); this page
  /// gets neither endpoint nor token. `acpmux-websocket`: a real socket, only for the browser dev
  /// slot (devHost.ts) and mock mode.
  transport: "acpmux-websocket" | "acpmux-bridge";
  endpoint?: string;
  token?: string;
  sessionId?: string;
  /** A pane opened as a new chat: do not fall back to the most recent session; the first prompt creates one. */
  newSession?: boolean;
  /** A tab's recorded session (`sessionId`) must exist. When the daemon has no such session, or it
   * goes away, the pane says so rather than showing another chat, and marks nothing seen. */
  sessionMustExist?: boolean;
  /** A new chat's working directory, inherited from the tab it was opened from. */
  cwd?: string;
  /** Text the composer starts with. Shown, never sent by itself. */
  draft?: string;
  /** A new chat's first prompt, sent once the client connects (onboarding's first task). */
  prompt?: string;
  /** An outside Claude Code or Codex chat this pane resumes once it connects. */
  adopt?: AcpmuxAdopt;
  /** A chat opened for its workspace (Cmd-I's chat dock): its first prompt carries the workspace
   *  context (workspaceContext.ts), hidden from the transcript. */
  workspaceContext?: boolean;
};

/** A harness's own session for acpmux to adopt (`_meta.acpmux.adopt`). */
export type AcpmuxAdopt = { harness: string; agentSessionId: string; ifLive?: "fork" | "open" };

/** `session/new` params: the host's cwd when it gave one, else acpmux's default. An adopt
 *  sends no cwd: acpmux resumes the chat where its harness recorded it. */
export function newSessionParams(
  host: Pick<AcpmuxHostConfig, "cwd" | "adopt"> & { peer?: string },
  harness?: string,
  noProject = false,
): Record<string, unknown> {
  if (host.adopt)
    return {
      mcpServers: [],
      _meta: { acpmux: { harness: harness ?? host.adopt.harness, adopt: host.adopt } },
    };
  return {
    ...(host.cwd ? { cwd: host.cwd } : {}),
    mcpServers: [],
    _meta: {
      acpmux: {
        harness,
        ...(host.peer ? { peer: host.peer } : {}),
        // Do not work in a project: the host starts the chat in its agent-home folder, not the
        // workspace's (AcpmuxPathPolicy), and strips this before acpmux sees it.
        ...(noProject ? { noProject: true } : {}),
      },
    },
  };
}

/** What an `adopt.live` refusal's details offer: a fork (Claude Code), and the holding process. */
function liveDetails(details: unknown): { canFork: boolean; command?: string } {
  const d = details && typeof details === "object" ? (details as Record<string, unknown>) : {};
  return {
    canFork: d.canFork === true,
    ...(typeof d.command === "string" && d.command ? { command: d.command } : {}),
  };
}

/** True when a `session/new` result resumed `adopt`. A daemon without adopt ignores the request
 *  and starts a fresh chat, whose `agentSessionId` is its own or absent. */
export function adoptedBy(result: any, adopt: AcpmuxAdopt): boolean {
  return result?._meta?.acpmux?.agentSessionId === adopt.agentSessionId;
}

export type EventRecord = {
  sessionId?: string;
  seq: number;
  at: number;
  dir: string;
  kind: string;
  msg: Record<string, any>;
};
type Session = Record<string, any> & { sessionId: string };
type Reply = {
  id: number;
  result?: any;
  error?: { message?: string; code?: unknown; data?: unknown };
};
type Notification = { method: string; params?: any };
type Listener = (snapshot: AcpmuxSnapshot) => void;

/// A hint that a harness is likely next, so acpmux can warm its adapter (cmux-tui acpmux lane).
export const PREWARM_METHOD = "_acpmux/prewarm";

/// The slash commands are not transcript, so the pane asks for their updates by kind.
/// How long Stop waits for the turn to end before the pane stops showing it as working. It is
/// shorter than acpmux's own grace (`CANCEL_GRACE`, 10 s), so a slow agent's turn stops showing
/// as working before acpmux's forced end and its note.
const STOP_GRACE_MS = 5_000;
const COMMANDS_KIND = "available_commands_update";
/// How much of the context window the session has used; not transcript, so attach asks for it by kind.
const USAGE_KIND = "usage_update";
/// The agent's own change of a config option (a reasoning level, a model): the whole option list.
const CONFIG_KIND = "config_option_update";
const SESSION_INFO_KIND = "session_info_update";
/// The chat's one session start row (conversation/SessionStartNote.tsx).
const SESSION_START_ROW = "session-start";
/// A record that opens a turn: older pages split before one, so each holds whole turns. A steer
/// joins the running turn, so it opens none.
const startsTurn = (event: EventRecord) =>
  event.dir === "mux" && event.kind === "user_message" && event.msg?.steer !== true;

/// Page size caps acpmux applies (maxBytes): opening a chat, then each older page as the reader scrolls up.
const OPEN_PAGE_BYTES = 128 * 1024;
const OLDER_PAGE_BYTES = 256 * 1024;
/** How long a session list that failed to load waits before it is read once more. */
const SESSION_REREAD_MS = 2000;
/// The longest a chat switch keeps the chat before on screen while the new one attaches.
const SWITCH_HOLD_MS = 400;
/// The longest a connect keeps the pane's last snapshot on screen while it reads the chat.
const OPEN_HOLD_MS = 1500;
/// An agent's secret card and its answer (cx-ncc.42): not transcript, so attach asks for them by kind.
const SECRET_KINDS = ["secret_request", "secret_decision"];
/// The promptId acpmux gives a task result's prompt: `offer-result-<offerId>` (hub/offers.rs).
const OFFER_RESULT_PROMPT = "offer-result-";
/// A queued prompt sent now (`queue_order` `next`) or edited (`queue_updated`): not transcript in
/// acpmux (`paging.rs`), so attach asks for them by kind, or the queue never hears either live.
const QUEUE_KINDS = ["queue_order", "queue_updated"];
/// acpmux's refusals of an answer to a card it no longer has (hub/secrets.rs): a restart lost it,
/// or the agent stopped waiting.
const SECRET_GONE = ["no secret request with that id", "the agent stopped waiting"];

export function permissionFromMessage(message: any, selectedSessionId: string): AcpmuxPermission | undefined {
  const envelope = message ?? {};
  const raw = envelope?.request ?? envelope;
  const sessionId = envelope?.sessionId ?? raw?.sessionId;
  const permissionId = envelope?.permissionId ?? raw?.permissionId;
  if (!permissionId || sessionId !== selectedSessionId) return undefined;
  const question = questionFromPermission({
    permissionId: String(permissionId),
    session: sessionId,
    request: raw,
  });
  const claudeMeta =
    raw.toolCall?._meta?.claude && typeof raw.toolCall._meta.claude === "object"
      ? raw.toolCall._meta.claude
      : undefined;
  const suggestions = Array.isArray(claudeMeta?.suggestions)
    ? claudeMeta.suggestions.flatMap((suggestion: unknown) => {
        if (typeof suggestion === "string" && suggestion.trim()) return [suggestion.trim()];
        if (!suggestion || typeof suggestion !== "object") return [];
        const rules = (suggestion as { rules?: unknown }).rules;
        return Array.isArray(rules)
          ? rules.flatMap((rule: unknown) => {
              if (typeof rule === "string" && rule.trim()) return [rule.trim()];
              if (!rule || typeof rule !== "object") return [];
              const value = rule as { toolName?: unknown; ruleContent?: unknown };
              const tool = typeof value.toolName === "string" ? value.toolName.trim() : "";
              const content = typeof value.ruleContent === "string" ? value.ruleContent.trim() : "";
              return [content || tool].filter(Boolean);
            })
          : [];
      })
    : [];
  return {
    ...(question ? { question } : {}),
    permissionId: String(permissionId),
    groupId: typeof envelope.groupId === "string" ? envelope.groupId : undefined,
    turnId: typeof envelope.turnId === "string" ? envelope.turnId : undefined,
    title: raw.toolCall?.title,
    command:
      typeof raw.toolCall?.command === "string"
        ? raw.toolCall.command
        : typeof raw.toolCall?.rawInput?.command === "string"
          ? raw.toolCall.rawInput.command
          : typeof raw.command === "string"
            ? raw.command
            : undefined,
    description:
      typeof claudeMeta?.description === "string"
        ? claudeMeta.description
        : typeof raw.toolCall?.description === "string"
          ? raw.toolCall.description
          : typeof raw.description === "string"
            ? raw.description
            : undefined,
    rule:
      suggestions.length > 0
        ? translate("permission.claude.alwaysAllowRule", { rules: suggestions.join(", ") })
        : typeof raw.toolCall?.rule === "string"
          ? raw.toolCall.rule
          : typeof raw.rule === "string"
            ? raw.rule
            : undefined,
    kind: raw.toolCall?.kind,
    ...(typeof raw.toolCall?.toolCallId === "string" ? { toolCallId: raw.toolCall.toolCallId } : {}),
    pending: true,
    options: (raw.options ?? []).map((option: any) => ({
      id: String(option.optionId ?? option.id),
      name: String(option.name ?? option.optionId),
      allow: String(option.kind ?? "").startsWith("allow"),
      kind: typeof option.kind === "string" ? option.kind : undefined,
      description: typeof option.description === "string" ? option.description : undefined,
      rule:
        typeof option.rule === "string"
          ? option.rule
          : typeof option.suggestion === "string"
            ? option.suggestion
            : undefined,
    })),
  };
}

function queuedEntry(id: string, prompt: string, next: boolean): QueuedPrompt {
  return next ? { id, prompt, next } : { id, prompt };
}

const oneLine = (text: string) => text.split(/\s+/).filter(Boolean).join(" ");

/// acpmux's queue (a session's `queue`, in order) over the one the pane has. acpmux lists each
/// prompt's preview (its first 200 characters on one line), so a prompt the pane read whole from
/// its `queued` record keeps its whole text, and one sent now stays next.
export function mergeQueue(current: readonly QueuedPrompt[], listed: readonly any[]): QueuedPrompt[] {
  const known = new Map(current.map((entry) => [entry.id, entry]));
  return listed.map((entry) => {
    const id = String(entry?.promptId ?? "");
    const preview = String(entry?.prompt ?? entry?.preview ?? "");
    const had = known.get(id);
    const whole = had !== undefined && oneLine(had.prompt).startsWith(preview.replace(/…$/, ""));
    return queuedEntry(id, whole ? had.prompt : preview, had?.next === true);
  });
}

export function settleOptimisticPrompt(
  rows: Map<string, AcpmuxRow>,
  promptRows: Map<string, string>,
  message: any,
): void {
  const promptId = typeof message?.promptId === "string" ? message.promptId : undefined;
  if (!promptId) return;
  const rowId = promptRows.get(promptId);
  if (rowId) rows.delete(rowId);
  promptRows.delete(promptId);
}

export function mergeEventRecords(...batches: EventRecord[][]): EventRecord[] {
  const bySequence = new Map<number, EventRecord>();
  for (const event of batches.flat()) bySequence.set(event.seq, event);
  return [...bySequence.values()].sort((left, right) => left.seq - right.seq);
}

export function applySupersededMessage(
  rows: Map<string, AcpmuxRow>,
  messageRows: Map<string, string[]>,
  superseded: Set<string>,
  oldMessageId: string,
): void {
  superseded.add(oldMessageId);
  for (const rowId of messageRows.get(oldMessageId) ?? []) rows.delete(rowId);
  messageRows.delete(oldMessageId);
}

/** The session to attach after connect: the selected one, else the most recent unless the pane is a new chat. */
export function initialSession(
  selected: string | undefined,
  sessions: { sessionId: string }[],
  newSession?: boolean,
): string | undefined {
  if (selected) return selected;
  return newSession ? undefined : sessions[0]?.sessionId;
}

/// The file changes in a tool call's content (ACP `diff` items), placed by the call's locations.
export function toolDiffs(content: any, locations: any): AcpmuxFileDiff[] | undefined {
  if (!Array.isArray(content)) return undefined;
  const lines = new Map<string, number>();
  for (const location of Array.isArray(locations) ? locations : [])
    if (
      typeof location?.path === "string" &&
      Number.isInteger(location.line) &&
      location.line > 0 &&
      !lines.has(location.path)
    )
      lines.set(location.path, location.line);
  const diffs = content
    .filter((item: any) => item?.type === "diff" && typeof item.path === "string" && typeof item.newText === "string")
    .map((item: any): AcpmuxFileDiff => ({
      path: item.path,
      oldText: typeof item.oldText === "string" ? item.oldText : undefined,
      newText: item.newText,
      line: lines.get(item.path),
    }));
  return diffs.length ? diffs : undefined;
}

/// Diffs placed again by an update that brings only locations.
function placeDiffs(diffs: AcpmuxFileDiff[] | undefined, locations: any): AcpmuxFileDiff[] | undefined {
  if (!diffs || !Array.isArray(locations)) return diffs;
  return (
    toolDiffs(
      diffs.map((diff) => ({ type: "diff", ...diff })),
      locations,
    ) ?? diffs
  );
}

/// A tool call folded with an update to it. ACP updates carry only the fields that changed;
/// content, when present, replaces the call's content. `at` is the event's time: the call
/// starts at its first event and ends at the first that reports it completed or failed.
export function mergeToolItem(
  previous: AcpmuxActivity | undefined,
  update: any,
  callId: string,
  output: string,
  at?: number,
): AcpmuxActivity {
  const before = previous?.tool;
  const title = update.title ?? update.name;
  const status = String(update.status ?? before?.status ?? "in_progress");
  const ended = status === "completed" || status === "failed";
  return {
    kind: "tool",
    text: String(title ?? previous?.text ?? callId),
    tool: {
      id: callId,
      title: String(update.title ?? before?.title ?? callId),
      kind: update.kind ?? before?.kind,
      status,
      inputSummary: update.rawInput ? JSON.stringify(update.rawInput) : before?.inputSummary,
      output:
        output || formattedOutput(update.rawOutput) || (update.content === undefined ? before?.output : undefined),
      command: shellCommand(update.rawInput) ?? before?.command,
      exitCode: exitCode(update.rawOutput) ?? before?.exitCode,
      startedAt: before?.startedAt ?? at,
      endedAt: before?.endedAt ?? (ended ? at : undefined),
      locations: Array.isArray(update.locations) ? update.locations : before?.locations,
      images: update.content === undefined ? before?.images : imagesFromContent(update.content),
      diffs:
        update.content === undefined
          ? placeDiffs(before?.diffs, update.locations)
          : toolDiffs(update.content, Array.isArray(update.locations) ? update.locations : before?.locations),
    },
  };
}

/// The command line a shell call ran, from `rawInput.command`: a string, or an argv array. An
/// argv that runs a script through a shell (`zsh -lc "cd x && bun test"`) shows the script;
/// otherwise a part with spaces or quotes is single-quoted, so the line reads as typed.
export function shellCommand(rawInput: any): string | undefined {
  const command = rawInput?.command;
  if (typeof command === "string") return command;
  if (!Array.isArray(command) || !command.every((part) => typeof part === "string") || !command.length)
    return undefined;
  const [program, flag, script] = command as string[];
  if (command.length === 3 && /(^|\/)(ba|z|da|fi)?sh$/.test(program!) && /^-l?c$/.test(flag!)) return script;
  return (command as string[])
    .map((part) => (/^[\w@%+=:,./-]+$/.test(part) ? part : `'${part.replace(/'/g, "'\\''")}'`))
    .join(" ");
}

function exitCode(rawOutput: any): number | undefined {
  const code = rawOutput?.exit_code ?? rawOutput?.exitCode;
  return typeof code === "number" ? code : undefined;
}

/// Codex reports a shell call's output in `rawOutput` when the call carries no content.
function formattedOutput(rawOutput: any): string {
  const text = rawOutput?.formatted_output;
  return typeof text === "string" ? text : "";
}

export function textFromContent(content: any): string {
  if (typeof content === "string") return content;
  if (content?.type === "text") return String(content.text ?? "");
  // A tool call's content blocks wrap their text: `{ type: "content", content: { type: "text" } }`.
  if (content?.type === "content") return textFromContent(content.content);
  if (Array.isArray(content)) return content.map(textFromContent).join("");
  return "";
}

/// The largest image block a tool call keeps (its base64 text): a bigger one is left out.
const MAX_TOOL_IMAGE_LENGTH = 8 * 1024 * 1024;

/// The data URLs of ACP `image` content blocks (`{type: "image", mimeType, data}`, bare or in a
/// `content` wrapper), images only and each under the cap.
function imagesFromContent(content: any): string[] | undefined {
  const found: string[] = [];
  const visit = (block: any) => {
    if (Array.isArray(block)) return block.forEach(visit);
    if (block?.type === "content") return visit(block.content);
    if (block?.type !== "image" || typeof block.data !== "string") return;
    const type = String(block.mimeType ?? "");
    if (/^image\/(png|jpeg|gif|webp)$/.test(type) && block.data.length <= MAX_TOOL_IMAGE_LENGTH)
      found.push(`data:${type};base64,${block.data}`);
  };
  visit(content);
  return found.length ? found : undefined;
}

function sessionUpdate(event: EventRecord): any | undefined {
  return event.dir === "in" && event.msg.method === "session/update" ? event.msg.params?.update : undefined;
}

/// Opens the client's socket; mock mode passes an in-page daemon (mock.ts), the app the host
/// bridge (bridgeSocket.ts).
export type OpenSocket = (url: URL) => WebSocket;

/// The placeholder URL of a bridge connection (never dialed).
export const BRIDGE_URL = "cmux-bridge://acpmux/";

/// Where git reads go: the native host, or in mock mode the daemon the socket reaches.
export type GitRoute = "native" | "daemon";

/// Runs `run` once before the next display frame, or after 50 ms when the page draws no frames
/// (a hidden pane), so a hidden transcript still keeps up.
export const nextFrame = (run: () => void) => {
  let ran = false;
  const once = () => {
    if (ran) return;
    ran = true;
    run();
  };
  requestAnimationFrame(once);
  setTimeout(once, 50);
};

/// A thought chunk continues the thought it follows: a thought streams into one growing item,
/// not one row per chunk. `at` (the chunk's time) dates the thought's first and latest chunk, so
/// a folded thought can read "Thought for 12s" (conversation/ThoughtRow.tsx `thoughtDuration`).
export function appendThought(items: AcpmuxActivity[], text: string, at?: number): AcpmuxActivity[] {
  const last = items.at(-1);
  if (last?.kind === "thought" && !last.tool)
    return [...items.slice(0, -1), { ...last, text: last.text + text, ...(at !== undefined && { endedAt: at }) }];
  return [...items, { kind: "thought", text, ...(at !== undefined && { startedAt: at, endedAt: at }) }];
}

/// Notices made in one millisecond each keep their row: the id carries a counter, not the time.
let notices = 0;
const noticeId = (kind: string) => `${kind}-${(notices += 1)}`;

/// The images a `user_message` names (`images: [{id, mimeType, name?}]`), malformed entries left out.
function promptImages(value: unknown): PromptImage[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((image) =>
    image && typeof image.id === "string" && typeof image.mimeType === "string"
      ? [
          {
            id: image.id,
            mimeType: image.mimeType,
            ...(typeof image.name === "string" && { name: image.name }),
          },
        ]
      : [],
  );
}

/// Transcript rows in the daemon's event order: each row keeps the sequence number of the event
/// that created it, so two wall clocks (or one millisecond) never put a prompt under its reply.
/// A row made without an event (a prompt sending or failed, a notice, the typing row) orders after
/// the events seen when it was made, so later turns go below it; after a lag rebuild, which
/// replays events older than it, it moves after them again.
export class OrderedRows extends Map<string, AcpmuxRow> {
  private readonly order = new Map<string, number>();
  private readonly local = new Set<string>();
  private made = 0;
  /// The sequence number of the event being reduced.
  current: number | undefined;
  /// The newest event reduced so far.
  private latest = 0;
  /// The rows in order as of the last ``sorted()``, and each one's index there: a snapshot of a
  /// long chat whose rows only changed in place copies this instead of sorting every row again.
  private ordered: AcpmuxRow[] | undefined;
  private orderedIndex = new Map<string, number>();

  /// Puts back the earlier object of each row a rebuild made again unchanged (same kind, version and
  /// plain fields: a turn's totals change with what was folded before it, not its version), so what
  /// is keyed on the object (drawn heights, memoized rows, reused turns) survives the rebuild: paging
  /// older history in rebuilds every row.
  keepSame(previous: ReadonlyMap<string, AcpmuxRow>): void {
    const plainSame = (a: AcpmuxRow, b: AcpmuxRow) => {
      const keys = new Set([...Object.keys(a), ...Object.keys(b)]) as Set<keyof AcpmuxRow>;
      for (const key of keys) if (typeof a[key] !== "object" && a[key] !== b[key]) return false;
      return true;
    };
    for (const [id, row] of this) {
      const old = previous.get(id);
      if (!old || old === row || old.kind !== row.kind || old.version !== row.version || !plainSame(old, row)) continue;
      super.set(id, old);
      const at = this.orderedIndex.get(id);
      if (this.ordered && at !== undefined) this.ordered[at] = old;
    }
  }

  override set(id: string, row: AcpmuxRow): this {
    const known = this.order.has(id);
    if (!known) {
      if (this.current !== undefined) {
        this.order.set(id, this.current);
        this.latest = Math.max(this.latest, this.current);
      } else {
        this.order.set(id, this.latest + 0.5 + (this.made += 1e-6));
        this.local.add(id);
      }
    } else if (this.current !== undefined) this.latest = Math.max(this.latest, this.current);
    if (this.ordered) this.keepOrdered(id, row, known);
    return super.set(id, row);
  }

  /// Updates the kept order for `row`: in its slot when only its content changed, at the end when it
  /// sorts after every row, otherwise ``sorted()`` sorts again.
  private keepOrdered(id: string, row: AcpmuxRow, known: boolean): void {
    const ordered = this.ordered!;
    const index = this.orderedIndex.get(id);
    if (known && index !== undefined && (ordered[index]!.at === row.at || this.ownsSlot(index))) {
      ordered[index] = row;
      return;
    }
    const last = ordered.at(-1);
    const order = this.order.get(id) ?? 0;
    const lastOrder = last ? (this.order.get(last.id) ?? 0) : -Infinity;
    if (!known && (order > lastOrder || (order === lastOrder && row.at >= last!.at))) {
      this.orderedIndex.set(id, ordered.length);
      ordered.push(row);
      return;
    }
    this.ordered = undefined;
  }

  /// Whether the row at `index` of the kept order sorts by its event alone, so a change of its
  /// time (the tie-break, which a streamed delta moves) cannot move it.
  private ownsSlot(index: number): boolean {
    const ordered = this.ordered!;
    const order = this.order.get(ordered[index]!.id);
    const before = ordered[index - 1];
    const after = ordered[index + 1];
    return (!before || this.order.get(before.id) !== order) && (!after || this.order.get(after.id) !== order);
  }

  /// The place `id` sorts at: its event's sequence number, or just after the events seen before it.
  orderOf(id: string): number {
    return this.order.get(id) ?? Infinity;
  }

  /// An event was reduced (it may have made no row).
  saw(seq: number): void {
    this.latest = Math.max(this.latest, seq);
  }

  override delete(id: string): boolean {
    // Every text delta drops the typing row, which is usually gone already.
    if (!this.has(id)) return false;
    this.ordered = undefined;
    this.order.delete(id);
    this.local.delete(id);
    return super.delete(id);
  }

  override clear(): void {
    this.ordered = undefined;
    this.order.clear();
    this.local.clear();
    this.latest = 0;
    super.clear();
  }

  /// Drops every row but those `keep` accepts; the event order starts over (a lag rebuild
  /// replays the events), and the rows kept go after the replayed events (``placeLocalLast()``).
  retain(keep: (row: AcpmuxRow) => boolean): void {
    // A Map visits the entries left after a delete, so deleting while iterating is safe.
    for (const row of this.values()) if (!keep(row)) this.delete(row.id);
    this.latest = 0;
  }

  /// Moves the rows made without an event after every event, keeping their order: what a lag
  /// rebuild replayed happened before them.
  placeLocalLast(): void {
    this.ordered = undefined;
    const local = [...this.local].sort((a, b) => (this.order.get(a) ?? 0) - (this.order.get(b) ?? 0));
    local.forEach((id, index) => this.order.set(id, this.latest + 0.5 + (index + 1) * 1e-6));
  }

  /// The rows in event order (wall-clock time breaks a tie).
  sorted(): AcpmuxRow[] {
    if (!this.ordered) {
      this.ordered = [...this.values()].sort(
        (a, b) => (this.order.get(a.id) ?? 0) - (this.order.get(b.id) ?? 0) || a.at - b.at,
      );
      this.orderedIndex = new Map(this.ordered.map((row, index) => [row.id, index]));
    }
    return this.ordered.slice();
  }
}

/** Direct browser client for the authenticated acpmux WebSocket protocol. */
export class AcpmuxDirectClient {
  /// Coalesces the snapshots of acpmux events that land within one display frame: a fast stream
  /// sends several deltas per frame, and each snapshot re-renders the transcript. The page that
  /// draws the transcript sets it (main.tsx: ``nextFrame``); unset, each event snapshots at once.
  static scheduleFrame: ((run: () => void) => void) | undefined;
  /// The connection state of the snapshot waiting for the next frame.
  private frameSnapshot?: string;
  private socket?: WebSocket;
  private nextRequest = 1;
  private pending = new Map<
    number,
    {
      resolve: (value: any) => void;
      reject: (error: Error) => void;
      timer?: ReturnType<typeof setTimeout>;
    }
  >();
  private events: EventRecord[] = [];
  private rows = new OrderedRows();
  /// Each drawn offer's row (a suggested tasks card), by offer id (offer/SuggestedTasks.tsx).
  private offerRows = new Map<string, string>();
  /// Offers whose result prompt reached this chat (its user_message): a replayed `queued` record
  /// of it draws no second line.
  private receivedOffers = new Set<string>();
  /// The chats started from this chat's offers, watched while they run for their rows' subtitles.
  private readonly offerChildren = new OfferChildren(
    (method, params) => this.request(method, params, 15000),
    () => this.selectedSessionId,
    (child) => this.childChanged(child),
  );
  private sessions: Session[] = [];
  /// The session list a page at a time: the newest page opens the chat, the rest follow (cx-2lv1k).
  private readonly sessionPages = new SessionPager<Session>((method, params) => this.request(method, params));
  private sessionReread: ReturnType<typeof setTimeout> | undefined;
  /// Sidebar entries by acpmux session object. A changed session arrives as a new object, so unchanged rows keep their entry and skip rendering.
  private sessionEntries = new WeakMap<Session, AcpmuxSessionEntry>();
  private selectedSessionId?: string;
  /** The session a link named that the daemon does not have (`sessionMustExist`). */
  private missingSession?: string;
  /** The adopt acpmux refused because its chat is live elsewhere, until the user picks a way on. */
  private liveAdopt?: { adopt: AcpmuxAdopt; canFork: boolean; command?: string };
  private summary: Record<string, any> | undefined;
  /// The event seq the summary's config options are current as of: attach's `lastSeq` (its session
  /// names the options it runs now), then each newer config update. A replayed update before it is
  /// history and never takes the current options back (a chat moved from Low to High).
  private configSeq = 0;
  private queue: QueuedPrompt[] = [];
  private pendingPermission?: AcpmuxPermission;
  private pendingSecret?: AcpmuxSecretAsk;
  private groupedPermissions = new Map<string, AcpmuxPermission>();
  /// The turn's open permission questions, and the edits that wait on one (cx-p5fgx): an edit
  /// is "pending" from its question, or from arriving while one is open, until it completes.
  private openQuestions = new Set<string>();
  private heldEdits = new Set<string>();
  private commands: SlashCommand[] = [];
  private usage: { used: number; size: number } | undefined;
  /// Set once an update for this session is applied, so an older fetched list cannot replace it.
  private commandsApplied = false;
  private optimisticPromptRows = new Map<string, string>();
  private optimisticPromptTexts = new Map<string, string>();
  /// Prompts of this pane that wait in acpmux's queue: their bubble went when they were queued,
  /// and comes back (failed, with Retry) if acpmux refuses them when their turn comes.
  private queuedSends = new Set<string>();
  /// The steers the agent has not read yet, by row (the reply that was streaming when one went
  /// still streams above it; a later message means the agent read them).
  private waitingSteers: { rowId: string; promptId?: string }[] = [];
  /// Prompts sent now to an agent that cannot steer (acpmux `queue_order` `next`): each stops the
  /// turn and runs next, so its row reads as sent now.
  private sentNow = new Set<string>();
  /// Attachments sent with a prompt until its user-message event gives it a durable row id.
  private optimisticPromptAttachments = new Map<string, ComposerAttachment[]>();
  /// Attachments for completed prompts, used when their turn is retried later.
  private retryAttachments = new Map<string, ComposerAttachment[]>();
  /// What a prompt's sender is told once acpmux took the prompt (its `user_message` echo, or the
  /// reply), by prompt id. A refusal comes before either, so the composer keeps the prompt.
  private promptAccepts = new Map<string, () => void>();
  /// A prompt that was not sent, by its row: what Retry sends again.
  private failedPrompts = new Map<string, { input: string; attachments: ComposerAttachment[] }>();
  private firstSeq?: number;
  private lastSeq = 0;
  private turnOpen = false;
  /// Stop got no answer within STOP_GRACE_MS: the turn no longer shows as working until the next
  /// one starts (an acpmux that waits on an agent ignoring the cancel).
  private stopGaveUp = false;
  private stopTimer?: ReturnType<typeof setTimeout>;
  /// The last seq seen when Stop was pressed: only a turn event after it answers that Stop. A
  /// rebuild (loadOlder, lag resync) replays older ones, which must not cancel the grace.
  private stopAfterSeq?: number;
  /// A fork's `forked` boundary event: its copied history ends there (cx-ncc.61's versions).
  private forkedAtSeq: number | undefined;
  /// Session replay (replay/ReplayScreen.tsx): the recorded events are folded only through this seq.
  private replayThrough?: number;
  /// This computer's clock minus the session's (an SSH or Cloud peer stamps events with its own
  /// clock): the smallest arrival lag of a live event, since delays only make it larger.
  private clockOffset?: number;
  /// acpmux lists `acp.session.fork` among the operations it serves.
  private canFork = false;
  private handoffSupported = false;
  /// The `_acpmux/*` methods acpmux's `initialize` lists (`_meta.acpmux.extensions`).
  private extensions: readonly string[] = [];
  /// acpmux calls this connection local (`_meta.acpmux.origin: "local"`). Without that, a
  /// WebSocket connection is remote-origin to acpmux, which never pools for it.
  private localOrigin = false;
  /// The origin acpmux names for this connection; `unknown` until (or unless) it names one.
  private origin: NonNullable<AcpmuxSnapshot["origin"]> = "unknown";
  /// `sessions` holds the daemon's list: its first page has been read.
  private listedSessions = false;
  readonly handoff = new HandoffClient(
    (method, params) => this.request(method, params, 15000),
    () => this.emit(),
  );
  readonly permissions = new PermissionGroupClient(
    (method, params) => this.request(method, params, 15000),
    () => {
      for (const group of this.permissions.state.groups)
        for (const item of group.items) if (item.state !== "pending") this.groupedPermissions.delete(item.permissionId);
      if (!this.permissions.state.supported && !this.pendingPermission)
        this.pendingPermission = [...this.groupedPermissions.values()].at(-1);
      this.emit();
    },
  );
  private forking = false;
  private streamingAssistant?: string;
  private streamingAssistantMessageId?: string;
  private streamingActivity?: string;
  /// The open turn's plan row: its later `plan` updates redraw this one list (cx-ncc.80).
  private planRow?: string;
  private supersededMessageIds = new Set<string>();
  /// The rows each message streamed into; tool calls split one message into several.
  private messageRows = new Map<string, string[]>();
  /// The activity row each tool call lives in, so a late update lands where the call began.
  private toolRows = new Map<string, string>();
  /// TodoWrite calls a drawn checklist stands for (cx-ncc.80): acpmux sends each one's plan just
  /// before it, so the call and its updates draw no tool row.
  private planCalls = new Set<string>();
  /// Subagents and their records, which draw as group rows (subagents/subagentFold.ts).
  private subagents = new SubagentFold();
  private readonly listener: Listener;
  private host: AcpmuxHostConfig;
  private peers: string[] = [];
  private reconnectTimer?: number;
  private reconnectDelay = 250;
  /// Called once when an established connection drops. The host then asks Swift
  /// for a fresh handshake, because a restarted daemon has a new port and token.
  private readonly onLost?: () => void;
  private opening = false;
  private hasConnected = false;
  private closed = false;
  private selectionGeneration = 0;
  /// The last attach sent, and what acpmux last accepted about whether the page shows its chat.
  private attaching: Promise<unknown> = Promise.resolve();
  private shownToAcpmux?: { sessionId: string; visible: boolean };
  private viewSync: Promise<void> = Promise.resolve();
  /// The selection generation whose attach reply has landed; lag resync waits for it.
  private attachedGeneration = -1;
  private historyExhausted = false;
  /// An older page is on its way: the reader's scroll asks again on every frame near the top.
  private loadingOlder?: Promise<void>;
  /// While an older page folds, the first sequence number the pane held before it.
  private foldingBelow: number | undefined;
  /// After a failed older page the next waits until then, so a reader near the top does not retry every frame.
  private olderRetryAt = 0;
  /// The daemon's harness list or a harness's models changed (`_acpmux/harnesses_changed`: a
  /// profile written, live model lists refreshed); the catalog re-reads (catalog.ts
  /// followHarnessChanges).
  onHarnessesChanged?: () => void;
  /// A prompt carrying the workspace context is on its way (send).
  private contextInFlight = false;

  private constructor(
    host: AcpmuxHostConfig,
    listener: Listener,
    onLost?: () => void,
    private readonly openSocket: OpenSocket = (url) => new WebSocket(url),
    private readonly gitRoute: GitRoute = "native",
    /// Every message on the socket and its lifecycle, for the ACP inspector (wire.ts).
    private readonly wire: AcpWireLog = acpWire,
  ) {
    this.host = host;
    this.listener = listener;
    this.onLost = onLost;
    this.selectedSessionId = host.sessionId;
    if (typeof document !== "undefined") document.addEventListener("visibilitychange", this.showChanged);
  }

  /// A client with no connection that shows one recorded session as it stood at a point in it
  /// (session replay, replay/ReplayScreen.tsx). `seekReplay` moves the point; nothing is ever sent.
  static replay(sessionId: string, events: EventRecord[], listener: Listener): AcpmuxDirectClient {
    const client = new AcpmuxDirectClient({ protocolVersion: 1, transport: "acpmux-bridge", sessionId }, listener);
    client.closed = true;
    client.events = events
      .filter((event) => event.seq > 0 && (event.sessionId ?? sessionId) === sessionId)
      .sort((a, b) => a.seq - b.seq);
    client.replayThrough = 0;
    return client;
  }

  /// Shows the replayed session through `throughSeq`. Moving forward folds only the events since;
  /// moving back folds again from the start.
  seekReplay(throughSeq: number): void {
    const from = this.replayThrough ?? 0;
    if (throughSeq === from) return;
    this.replayThrough = throughSeq;
    if (throughSeq < from) this.rebuild();
    else
      for (const event of this.events) {
        if (event.seq <= from || event.seq > throughSeq) continue;
        this.lastSeq = event.seq;
        this.firstSeq ??= event.seq;
        this.reduce(event);
      }
    this.emit("replay");
  }

  /// Every recorded transcript event of a session, oldest first, for session replay.
  async recordedEvents(sessionId: string): Promise<EventRecord[]> {
    const events: EventRecord[] = [];
    for (let after = 0; ;) {
      const page = await this.request("_acpmux/events", {
        sessionId,
        afterSeq: after,
        limit: 2000,
        kinds: ["transcript"],
      });
      const batch: EventRecord[] = page?.events ?? [];
      events.push(...batch);
      const last = batch.at(-1)?.seq;
      if (!page?.hasMore || last === undefined || last <= after) return events;
      after = last;
    }
  }

  static async connect(
    host: AcpmuxHostConfig,
    listener: Listener,
    onLost?: () => void,
    openSocket?: OpenSocket,
    gitRoute?: GitRoute,
    wire?: AcpWireLog,
  ): Promise<AcpmuxDirectClient> {
    const client = new AcpmuxDirectClient(host, listener, onLost, openSocket, gitRoute, wire);
    await client.open();
    return client;
  }

  private async open(): Promise<void> {
    if (this.opening || this.closed) return;
    this.opening = true;
    // Over the bridge the URL names nothing: the host knows its daemon.
    const url = new URL(this.host.endpoint ?? BRIDGE_URL);
    if (this.host.token) url.searchParams.set("token", this.host.token);
    this.wire.lifecycle("connecting", {
      endpoint: this.host.endpoint ? redactEndpoint(this.host.endpoint) : BRIDGE_URL,
      sessionId: this.selectedSessionId,
    });
    await new Promise<void>((resolve, reject) => {
      const socket = this.openSocket(url);
      this.socket = socket;
      let opened = false;
      socket.onopen = () => {
        opened = true;
        this.wire.lifecycle("open");
        resolve();
      };
      socket.onerror = () => {
        this.wire.lifecycle("error", { message: opened ? "WebSocket error" : "Unable to connect" });
        this.opening = false;
        reject(new Error(translate("error.connectFailed")));
      };
      socket.onclose = (event?: CloseEvent) => {
        if (this.socket !== socket) return;
        this.wire.lifecycle("close", {
          code: event?.code,
          reason: event?.reason || undefined,
          wasClean: event?.wasClean,
          established: opened,
        });
        if (!opened) {
          this.opening = false;
          reject(new Error(translate("error.closedBeforeConnect")));
          return;
        }
        this.handoff.disconnect();
        // acpmux drops a connection's attaches with it; the next attach watches them again.
        this.offerChildren.reset(false);
        this.groupedPermissions.clear();
        this.permissions.disconnected();
        this.rejectPending();
        this.emit("disconnected");
        if (!this.hasConnected || this.closed) return;
        if (this.onLost) {
          this.wire.lifecycle("lost", { message: "asking for a fresh handshake" });
          const onLost = this.onLost;
          this.close();
          onLost();
        } else this.scheduleReconnect();
      };
      socket.onmessage = (message) => acpmuxPerf.timed("client.receive", () => this.receive(String(message.data)));
    });
    // The pane keeps what it shows (the page's cached chat, or the chat before a reconnect) until
    // the open has read the chat: no half-read frame (an empty transcript, no composer) in between.
    const hold = this.holdSnapshots(OPEN_HOLD_MS);
    try {
      const initialized = await this.request("initialize", {
        protocolVersion: 1,
        clientInfo: { name: "cmux-react-agent-pane", version: "1" },
        clientCapabilities: {},
      });
      this.canFork = servesOperation(initialized, FORK_OP);
      const extensions = initialized?._meta?.acpmux?.extensions;
      this.extensions = Array.isArray(extensions) ? extensions.map(String) : [];
      this.localOrigin = initialized?._meta?.acpmux?.origin === "local";
      const origin = initialized?._meta?.acpmux?.origin;
      this.origin = origin === "local" || origin === "remote" || origin === "peer" ? origin : "unknown";
      this.handoffSupported = supportsHandoff(initialized);
      const groupedPermissionsSupported = supportsPermissionGroups(initialized);
      if (!groupedPermissionsSupported) this.groupedPermissions.clear();
      this.permissions.configure(groupedPermissionsSupported);
      const status = await this.request("_acpmux/status", {}).catch(() => undefined);
      this.peers = Array.isArray(status?.peers)
        ? status.peers
            .map((peer: any) => (typeof peer?.name === "string" ? peer.name : undefined))
            .filter((peer: string | undefined): peer is string => Boolean(peer))
        : [];
      const first = await this.sessionPages.first();
      let laterPages = first?.next ? first : undefined;
      const linkedLater =
        first !== undefined &&
        laterPages !== undefined &&
        this.selectedSessionId !== undefined &&
        !first.sessions.some((session) => session.sessionId === this.selectedSessionId);
      if (first && !linkedLater) this.sessions = first.sessions;
      else {
        // A linked chat older than the first page, or a lagged watch restarted the list: read the
        // whole list before calling the chat missing.
        this.sessions = this.sessionPages.settle(await this.sessionPages.whole());
        laterPages = undefined;
      }
      this.listedSessions = first !== undefined || this.sessions.length > 0;
      if (this.selectedSessionId && !this.sessions.some((session) => session.sessionId === this.selectedSessionId)) {
        // A linked session the daemon lacks is refused, never replaced by the most recent chat.
        if (this.host.sessionMustExist) this.missingSession = this.selectedSessionId;
        this.selectedSessionId = this.host.sessionMustExist ? undefined : this.sessions[0]?.sessionId;
        this.selectionGeneration += 1;
        this.resetSessionState();
      }
      this.selectedSessionId = initialSession(
        this.selectedSessionId,
        this.sessions,
        this.host.newSession || this.missingSession !== undefined,
      );
      if (this.selectedSessionId) this.markSeen(this.selectedSessionId);
      // A reconnect to the same session keeps its transcript; the attach page holds only the newest events.
      const resumeAfter = this.lastSeq;
      const sessionId = this.selectedSessionId;
      const generation = this.selectionGeneration;
      if (sessionId) {
        const page = await this.attach(sessionId, generation);
        const oldest = page.length > 0 ? Math.min(...page.map((event) => event.seq)) : 0;
        if (resumeAfter > 0 && oldest > resumeAfter + 1)
          await this.fetchMissedEvents(sessionId, generation, resumeAfter, false);
      } else if (this.host.adopt) {
        await this.adoptChat(this.host.adopt);
      }
      this.hasConnected = true;
      this.reconnectDelay = 250;
      this.wire.lifecycle("connected", {
        sessionId: this.selectedSessionId,
        sessions: this.sessions.length,
      });
      this.emit("connected");
      if (laterPages) void this.readLaterSessions(laterPages);
    } catch (error) {
      this.wire.lifecycle("connect failed", {
        message: error instanceof Error ? error.message : String(error),
      });
      this.socket?.close();
      throw error;
    } finally {
      this.opening = false;
      this.releaseSnapshots(hold);
    }
  }

  /** Drops everything that belongs to the previously selected session, before another one attaches. */
  private resetSessionState(): void {
    // The chats started from the chat before are no longer watched.
    this.offerChildren.reset(this.socket?.readyState === WebSocket.OPEN);
    clearTimeout(this.stopTimer);
    this.stopGaveUp = false;
    this.stopAfterSeq = undefined;
    this.events = [];
    this.historyExhausted = false;
    this.olderRetryAt = 0;
    // A page still in flight belongs to the session before; it is dropped when it lands.
    this.loadingOlder = undefined;
    this.rows.clear();
    this.forkedAtSeq = undefined;
    this.failedPrompts.clear();
    this.firstSeq = undefined;
    this.lastSeq = 0;
    this.clockOffset = undefined;
    this.summary = undefined;
    this.configSeq = 0;
    this.usage = undefined;
    this.queue = [];
    this.turnOpen = false;
    this.streamingAssistant = undefined;
    this.streamingAssistantMessageId = undefined;
    this.streamingActivity = undefined;
    this.planRow = undefined;
    this.optimisticPromptRows.clear();
    this.optimisticPromptTexts.clear();
    this.optimisticPromptAttachments.clear();
    this.queuedSends.clear();
    this.waitingSteers = [];
    this.sentNow.clear();
    this.retryAttachments.clear();
    this.supersededMessageIds.clear();
    this.messageRows.clear();
    this.offerRows.clear();
    this.receivedOffers.clear();
    this.toolRows.clear();
    this.planCalls.clear();
    this.planRow = undefined;
    this.subagents = new SubagentFold();
    this.pendingPermission = undefined;
    this.pendingSecret = undefined;
    this.groupedPermissions.clear();
    this.openQuestions.clear();
    this.heldEdits.clear();
    this.commands = [];
    this.commandsApplied = false;
    this.handoff.select(this.selectedSessionId);
    this.permissions.select(this.selectedSessionId);
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer !== undefined || this.closed) return;
    const delay = this.reconnectDelay;
    this.reconnectDelay = Math.min(delay * 2, 30_000);
    this.wire.lifecycle("reconnect scheduled", { delayMs: delay });
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = undefined;
      void this.open().catch(() => this.scheduleReconnect());
    }, delay);
  }

  private receive(raw: string): void {
    this.wire.received(raw);
    let message: Reply | Notification;
    try {
      message = JSON.parse(raw) as Reply | Notification;
    } catch {
      return;
    }
    if ("id" in message && typeof message.id === "number") {
      const request = this.pending.get(message.id);
      if (!request) return;
      this.pending.delete(message.id);
      if (request.timer) clearTimeout(request.timer);
      // The failure's code (`validation.invalid`, ...) and details ride along for callers that
      // tell failures apart.
      if (message.error) {
        const data = message.error.data as
          | { code?: unknown; details?: unknown; reason?: unknown; detail?: unknown }
          | undefined;
        request.reject(
          Object.assign(new AcpmuxRpcError(message.error), {
            code: data?.code ?? message.error.code,
            ...(data?.details === undefined ? {} : { details: data.details }),
            // acpmux's own refusals name their reason (`trust.pending`, `remote.mode_not_asking`).
            ...(typeof data?.reason === "string" ? { reason: data.reason } : {}),
            // A host refusal can carry acpmux's own words (a refused Enable harness prompt).
            ...(typeof data?.detail === "string" ? { detail: data.detail } : {}),
            // A trust refusal names the folder it asks about (the folder acpmux resolved).
            ...(typeof (data as { cwd?: unknown } | undefined)?.cwd === "string"
              ? { cwd: (data as { cwd: string }).cwd }
              : {}),
          }),
        );
      } else request.resolve(message.result);
      return;
    }
    const notification = message as Notification;
    if (notification.method === "_acpmux/event") {
      // A chat started from an offer here, watched for its row (offer/offerChildren.ts).
      const params = notification.params ?? {};
      if (params.sessionId !== this.selectedSessionId && this.offerChildren.event(params)) return;
      this.observeClock(notification.params?.sessionId, notification.params?.at);
      this.apply(notification.params as EventRecord);
    } else if (notification.method === "session/update") {
      this.observeClock(notification.params?.sessionId, notification.params?._meta?.acpmux?.at);
      this.apply({
        sessionId: notification.params?.sessionId,
        seq: Number(notification.params?._meta?.acpmux?.seq ?? 0),
        at: Number(notification.params?._meta?.acpmux?.at ?? Date.now()),
        dir: "in",
        kind: String(notification.params?.update?.sessionUpdate ?? ""),
        msg: { method: "session/update", params: { update: notification.params?.update } },
      });
    } else if (isNotification(notification, "_acpmux/session_changed")) this.sessionChanged(notification.params);
    else if (isNotification(notification, "_acpmux/permission_pending")) this.applyPermission(notification.params);
    else if (notification.method === "_acpmux/lagged") this.resyncAfterLag(notification.params);
    else if (notification.method === "_acpmux/harnesses_changed") this.onHarnessesChanged?.();
    // A new chat's start mode may have changed (a pick in any pane, a config reload): pending
    // chats ask acpmux again (startMode.ts).
    else if (notification.method === "_acpmux/start_mode_changed") startModeChanged();
  }

  /// The daemon dropped events for this client. Fetch what came after the last
  /// one seen and merge it in, keeping the transcript on screen meanwhile.
  /// agent-gui daemons send {sessionIds, watch, dropped}; older ones send only
  /// {dropped}, so a notice without sessionIds resyncs the selected session.
  private resyncAfterLag(params: any): void {
    if (params?.watch === true) void this.refreshSessions().catch(() => this.rereadSessionsLater());
    const sessionId = this.selectedSessionId;
    // Before the attach reply lands there is no cursor; the reply carries the latest events.
    if (!sessionId || this.attachedGeneration !== this.selectionGeneration) return;
    if (Array.isArray(params?.sessionIds) && !params.sessionIds.map(String).includes(sessionId)) return;
    this.emit("resyncing");
    void this.permissions.refresh().catch(() => {});
    const generation = this.selectionGeneration;
    void this.fetchMissedEvents(sessionId, generation, this.lastSeq).catch(() => {
      if (!this.closed && generation === this.selectionGeneration)
        this.emit(this.socket?.readyState === WebSocket.OPEN ? "failed" : "disconnected");
    });
  }

  /// Pages from its own cursor: live events keep advancing lastSeq meanwhile.
  /// The live summary, queue and permission survive the rebuild; after a lag the
  /// missed events are replayed onto them, while a fresh attach is already current.
  private async fetchMissedEvents(
    sessionId: string,
    generation: number,
    afterSeq: number,
    replayLiveState = true,
  ): Promise<void> {
    for (let cursor = afterSeq; ;) {
      const result = await this.request("_acpmux/events", {
        sessionId,
        afterSeq: cursor,
        limit: 5_000,
      });
      if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return;
      const missed: EventRecord[] = result?.events ?? [];
      this.events = mergeEventRecords(this.events, missed);
      this.rebuildKeepingLiveState(replayLiveState ? cursor : undefined);
      if (result?.hasMore !== true || missed.length === 0) break;
      cursor = Math.max(cursor, ...missed.map((event) => event.seq));
    }
    this.emit("resynced");
  }

  /// session_changed notices dropped by a watch lag: reread the whole list.
  /// A selection made while the request was out is newer than the list.
  private async refreshSessions(): Promise<void> {
    const generation = this.selectionGeneration;
    const first = await this.sessionPages.first();
    // A newer reread started meanwhile; it sets the list.
    if (!first) return;
    let list = first.sessions;
    const add = (more: Session[]) => {
      list = [...list, ...more];
    };
    if (first.next && !(await this.sessionPages.rest(first, () => list, add))) return;
    // Changes that came while the pages did are newer than the pages.
    this.sessions = this.sessionPages.settle(list);
    const missing =
      this.selectedSessionId !== undefined &&
      !this.sessions.some((session) => session.sessionId === this.selectedSessionId);
    if (missing && generation === this.selectionGeneration) this.selectFallbackSession("session changed");
    else this.emit("session changed");
  }

  /// The selected session is gone: a tab bound to its session (`sessionMustExist`) says so;
  /// any other pane shows the most recent remaining one, or none.
  private selectFallbackSession(reason: string): void {
    if (this.host.sessionMustExist) this.missingSession = this.selectedSessionId;
    this.selectedSessionId = this.host.sessionMustExist ? undefined : this.sessions[0]?.sessionId;
    if (this.selectedSessionId) this.markSeen(this.selectedSessionId);
    const generation = ++this.selectionGeneration;
    const hold = this.selectedSessionId ? this.holdSnapshots(SWITCH_HOLD_MS) : undefined;
    this.resetSessionState();
    this.emit(reason);
    if (this.selectedSessionId)
      void this.attach(this.selectedSessionId, generation)
        .catch(() => undefined)
        .finally(() => {
          if (hold !== undefined) this.releaseSnapshots(hold);
        });
  }

  /// The pages after the first, read once the chat is open. acpmux owns `unread` (cx-n8ou): the
  /// pane only tells it whether it shows its chat (`attach` `visible`, `_acpmux/view`).
  private async readLaterSessions(first: SessionPage<Session>): Promise<void> {
    await this.sessionPages.rest(first, () => this.sessions, this.addSessions).catch(() => this.rereadSessionsLater());
  }

  /// A list that could not be read to its end (a page and the whole-list fallback both failed)
  /// is read again once, a moment later, rather than left at the pages that came.
  private rereadSessionsLater(): void {
    if (this.closed || this.sessionReread) return;
    this.sessionReread = setTimeout(() => {
      this.sessionReread = undefined;
      if (!this.closed) void this.refreshSessions().catch(() => undefined);
    }, SESSION_REREAD_MS);
  }

  private addSessions = (more: Session[]): void => {
    this.sessions = [...this.sessions, ...more];
    if (!this.opening) this.emit("session changed");
  };

  /// The page was hidden or shown (a tab in a background workspace, an occluded window): acpmux
  /// leaves a turn that ends while nobody shows the chat unread, and showing it is seeing it.
  private showChanged = (): void => {
    const sessionId = this.selectedSessionId;
    if (!sessionId || this.closed) return;
    this.syncView();
    if (pageShown()) this.markSeen(sessionId);
  };

  /// Brings acpmux's view of the selected chat up to the page's. acpmux handles each request on
  /// its own task, so a view must wait for the attach it changes and for the view before it.
  private syncView(): void {
    const generation = this.selectionGeneration;
    this.viewSync = this.viewSync.then(async () => {
      await this.attaching;
      const sessionId = this.selectedSessionId;
      const visible = pageShown();
      if (
        generation !== this.selectionGeneration ||
        !sessionId ||
        this.closed ||
        this.shownToAcpmux?.sessionId !== sessionId
      )
        return;
      if (this.shownToAcpmux.visible === visible) return;
      await this.request("_acpmux/view", { sessionId, visible }).then(
        () => {
          if (generation === this.selectionGeneration && this.selectedSessionId === sessionId)
            this.shownToAcpmux = { sessionId, visible };
        },
        () => undefined,
      );
    });
  }

  /// Selecting a session is seeing it, including an unread flag acpmux sent.
  private markSeen(sessionId: string): void {
    this.sessions = this.sessions.map((session) =>
      session.sessionId === sessionId && session.unread === true ? { ...session, unread: false } : session,
    );
  }

  /// Whether the user trusts `cwd` (folderTrust.ts).
  trustGet(cwd: string): Promise<unknown> {
    return this.request("acp.trust.get", {
      cwd,
      ...(this.selectedSessionId ? { sessionId: this.selectedSessionId } : {}),
    });
  }

  /// Records the user's trust in `cwd` in acpmux's own record, never the agents' config files (folderTrust.ts).
  trustSet(cwd: string, level: string): Promise<unknown> {
    return this.request("acp.trust.set", {
      cwd,
      level,
      ...(this.selectedSessionId ? { sessionId: this.selectedSessionId } : {}),
    });
  }

  /// Stops one of the selected session's running subagents (a Claude agent or workflow); acpmux
  /// sends Claude's stop_task and answers with Claude's answer, and the subagent ends as cancelled
  /// when Claude stops it. A Claude that never answers fails it after 10 s.
  stopSubagent(subagentSessionId: string): Promise<unknown> {
    if (!this.selectedSessionId) return Promise.reject(new Error());
    return this.request("_acpmux/subagent_stop", { sessionId: this.selectedSessionId, subagentSessionId }, 10_000);
  }

  /// Reads the selected session's durable composer draft from acpmux.
  readDraft(sessionId: string): Promise<unknown> {
    return this.request("_acpmux/draft_get", { sessionId });
  }

  /// Persists or clears the selected session's composer draft in acpmux.
  writeDraft(sessionId: string, text: string): Promise<unknown> {
    return this.request("_acpmux/draft_set", { sessionId, text });
  }

  /// The session's prompt bookmarks (`{bookmarks: [seq...]}`), kept in acpmux (threadMinimap/bookmarks.ts).
  readBookmarks(sessionId: string): Promise<unknown> {
    return this.request("_acpmux/bookmark_get", { sessionId });
  }

  /// Marks or unmarks the prompt logged at `seq`; acpmux answers with the session's marks.
  setBookmark(sessionId: string, seq: number, bookmarked: boolean): Promise<unknown> {
    return this.request("_acpmux/bookmark_set", { sessionId, seq, bookmarked });
  }

  /// Files under `path` (else the selected session's folder) whose path matches `query`, best
  /// first (fileSearchModel.ts). acpmux serves no file search: the native host runs it on the
  /// session host as `git.files.search`, and mock mode's in-page daemon answers it.
  fileSearch(path: string | undefined, query: string, limit: number): Promise<unknown> {
    if (this.gitRoute === "daemon") return this.request("file.search", { ...(path ? { path } : {}), query, limit });
    const sessionId = this.selectedSessionId;
    const summary = this.summary?.sessionId === sessionId ? this.summary : undefined;
    const entry = this.sessions.find((session) => session.sessionId === sessionId);
    const cwd = path ?? text(summary?.cwd) ?? text(entry?.cwd);
    if (!cwd) return Promise.reject(new Error(translate("error.noFolderSearch")));
    return postNative("file.search", { cwd, query, limit });
  }

  /// The selected session's repository changes in one git scope (changes/model.ts); `narrow` names
  /// files (`paths`) and their unchanged context (`context_lines`, changes/wholeFile.ts).
  gitDiff(scope: string, narrow: { paths?: string[]; context_lines?: number } = {}): Promise<unknown> {
    return this.git("git.diff", { scope, include_patch: true, ...narrow });
  }

  /// The selected session's branch, upstream and how far it is ahead and behind.
  gitStatus(): Promise<unknown> {
    return this.git("git.status", {});
  }

  /// Commits in the selected session's repository (`git.commit`; changes/gitWrite.ts builds
  /// the params and the idempotency key).
  gitCommit(params: Record<string, unknown>): Promise<unknown> {
    if (this.gitRoute === "daemon") return Promise.reject(new Error(translate("error.noFolderChanges")));
    return this.git("git.commit", params);
  }

  /// Pushes the selected session's branch (`git.push`); never forced.
  gitPush(params: Record<string, unknown>): Promise<unknown> {
    if (this.gitRoute === "daemon") return Promise.reject(new Error(translate("error.noFolderChanges")));
    return this.git("git.push", params);
  }

  /// Stages (or unstages) files of the selected session's repository, named as `git.diff` names
  /// them. Only the native host on this Mac writes: a chat read through a daemon has no Stage.
  gitStage(paths: string[], unstage: boolean): Promise<unknown> {
    if (this.gitRoute === "daemon") return Promise.reject(new Error(translate("error.noFolderChanges")));
    return this.git(unstage ? "git.unstage" : "git.stage", { paths });
  }

  /// Stages (or unstages) one hunk of a file (and a rename's previous path), named as for `gitStage`: `hunk` is its lines as
  /// `git.diff` showed them, and the native host applies only the hunk it finds with those lines.
  gitStageHunk(paths: string[], hunk: string[], unstage: boolean): Promise<unknown> {
    if (this.gitRoute === "daemon") return Promise.reject(new Error(translate("error.noFolderChanges")));
    return this.git(unstage ? "git.unstageHunk" : "git.stageHunk", { paths, hunk });
  }

  /// Opens the pull request of the selected session's pushed branch (`{url, number}`), or with
  /// `{action: "threads"}` reads its review threads (`{url, number, threads}`), or with
  /// `{action: "merge", number, url}` merges it (cx-ncc.77.4). Only the native host on this Mac runs
  /// it, as for Stage.
  gitPullRequest(params: { action?: "threads" | "merge"; number?: number; url?: string } = {}): Promise<unknown> {
    if (this.gitRoute === "daemon") return Promise.reject(new Error(translate("error.noFolderChanges")));
    return this.git("git.pullRequest", params);
  }

  /// acpmux serves no git methods: the native host runs them on the session host in the selected
  /// session's folder, and mock mode's in-page daemon answers them by session.
  /// One turn's repository changes: checkpoint `from` against checkpoint `to`.
  gitCheckpointDiff(from: string, to: string): Promise<unknown> {
    return this.git("git.checkpoint.diff", { from, to, include_patch: true });
  }

  private git(
    method:
      | "git.diff"
      | "git.status"
      | "git.checkpoint.diff"
      | "git.commit"
      | "git.push"
      | "git.stage"
      | "git.unstage"
      | "git.stageHunk"
      | "git.unstageHunk"
      | "git.pullRequest",
    params: Record<string, unknown>,
  ): Promise<unknown> {
    const sessionId = this.selectedSessionId;
    const summary = this.summary?.sessionId === sessionId ? this.summary : undefined;
    const entry = this.sessions.find((session) => session.sessionId === sessionId);
    const cwd = text(summary?.cwd) ?? text(entry?.cwd);
    if (!sessionId || !cwd) return Promise.reject(new Error(translate("error.noFolderChanges")));
    // The native host runs the read on the machine whose acpmux runs the session (a Cloud or
    // SSH machine's chat reads through that machine's daemon), so no page-side machine check.
    // The host refuses a commit or push whose session folder is not on this Mac.
    const asked =
      this.gitRoute === "daemon"
        ? this.request(method, { sessionId, cwd, ...params })
        : postNative(method, { cwd, ...params });
    // A status read names the session it read, so a commit or push built on it says which
    // session's repository the reader saw; the host refuses one for another session.
    return method === "git.status"
      ? asked.then((value) =>
          value && typeof value === "object" ? { ...(value as object), session_id: sessionId } : value,
        )
      : asked;
  }

  private request(method: string, params: Record<string, unknown>, deadline?: number): Promise<any> {
    if (this.socket?.readyState !== WebSocket.OPEN)
      return Promise.reject(
        Object.assign(new Error(translate("error.notOpen")), {
          code: "native.not_connected",
          origin: "native",
        }),
      );
    const id = this.nextRequest++;
    return new Promise((resolve, reject) => {
      const timer = deadline
        ? setTimeout(() => {
            this.pending.delete(id);
            reject(
              Object.assign(new Error(translate("error.timedOut")), {
                code: "native.timed_out",
                origin: "native",
              }),
            );
          }, deadline)
        : undefined;
      this.pending.set(id, { resolve, reject, timer });
      const text = JSON.stringify({ jsonrpc: "2.0", id, method, params });
      this.wire.sent(text, method, id);
      this.socket!.send(text);
    });
  }

  /// Returns the attach page's events, or none when the selection moved on.
  private async attach(sessionId: string, generation = this.selectionGeneration): Promise<EventRecord[]> {
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return [];
    const visible = pageShown();
    const attaching = this.request("_acpmux/attach", {
      sessionId,
      limit: 400,
      // The most opening a chat downloads, however large its tool output (a remote session's open).
      maxBytes: OPEN_PAGE_BYTES,
      // At most 8 kinds: a remote cmux-tui before cx-kpd0v refuses more. Session offers come with
      // "transcript" (acpmux paging.rs, since offers exist). The queue's live kinds go only to a
      // local acpmux, which takes any number; a remote chat's queue follows its session changes.
      kinds: [
        "transcript",
        COMMANDS_KIND,
        USAGE_KIND,
        CONFIG_KIND,
        BOOKMARKS_KIND,
        ...SECRET_KINDS,
        ...(this.localOrigin ? QUEUE_KINDS : []),
      ],
      eventStream: true,
      visible,
    });
    this.attaching = attaching.then(
      () => {
        if (generation === this.selectionGeneration && this.selectedSessionId === sessionId)
          this.shownToAcpmux = { sessionId, visible };
      },
      () => undefined,
    );
    const result = await attaching;
    this.syncView();
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return [];
    const page: EventRecord[] = result?.events ?? [];
    // An agent usually lists its commands once, at start, which is older than the page.
    if (
      !page.some((event) => event.kind === COMMANDS_KIND) &&
      typeof result?.lastSeq === "number" &&
      result.lastSeq > 0
    )
      void this.fetchCommands(sessionId, generation, result.lastSeq).catch(() => {});
    const detail = result?.session ?? {};
    this.summary = detail;
    this.configSeq = Array.isArray(detail.configOptions) && typeof result?.lastSeq === "number" ? result.lastSeq : 0;
    this.queue = [];
    this.events = mergeEventRecords(page, this.events);
    this.rebuild();
    // acpmux's list is the order; the replayed `queued` records give each prompt its whole text.
    this.queue = mergeQueue(this.queue, detail.queue ?? []);
    // acpmux holds nothing older than the page: the pane offers no more history.
    if (result?.hasMore === false) this.historyExhausted = true;
    this.attachedGeneration = generation;
    this.permissions.select(sessionId);
    await this.permissions.refresh().catch(() => {});
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return [];
    if (Array.isArray(detail.pending)) {
      const groupedIds = new Set(
        this.permissions.state.supported
          ? this.permissions.state.groups.flatMap((group) => group.items.map((item) => item.permissionId))
          : [],
      );
      this.pendingPermission = detail.pending
        .map((item: any) => permissionFromMessage({ ...item, sessionId }, sessionId))
        .find(
          (item: AcpmuxPermission | undefined) =>
            item && (!this.permissions.state.supported || (!item.groupId && !groupedIds.has(item.permissionId))),
        );
    }
    if (this.handoffSupported) {
      this.handoff.select(sessionId);
      try {
        await this.handoff.refresh();
      } catch {
        /* No mutation until a recovery read succeeds. */
      }
    }
    if (generation !== this.selectionGeneration) return [];
    this.emit("attached");
    return page;
  }

  /// The newest command list at or before `lastSeq`, unless a live update already arrived.
  private async fetchCommands(sessionId: string, generation: number, lastSeq: number): Promise<void> {
    const result = await this.request("_acpmux/events", {
      sessionId,
      beforeSeq: lastSeq + 1,
      limit: 1,
      kinds: [COMMANDS_KIND],
    });
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId || this.commandsApplied) return;
    const event: EventRecord | undefined = result?.events?.at(-1);
    const commands = event ? commandsFromUpdate(sessionUpdate(event)) : undefined;
    if (!commands) return;
    this.commands = commands;
    this.emit("commands");
  }

  private sessionChanged(params: SessionChanged): void {
    // Only a purge carries the id alone; every other change carries the whole summary.
    const session = params?.session as SessionSummary | undefined;
    if (params?.kind === "purged" && session?.sessionId) {
      this.sessionPages.purgedSession(session.sessionId);
      this.sessions = this.sessions.filter((item) => item.sessionId !== session.sessionId);
      if (session.sessionId === this.selectedSessionId && this.handoff.state.busy !== "discarding")
        this.selectFallbackSession("session purged");
      else this.emit("session purged");
      return;
    }
    if (!session?.sessionId) return;
    this.sessionPages.changedSession(session);
    this.sessions = [...this.sessions.filter((item) => item.sessionId !== session.sessionId), session];
    if (session.sessionId === this.selectedSessionId) {
      this.summary = { ...this.summary, ...session };
      // A change that doesn't carry the queue keeps the one already mapped.
      if (session.queue) this.queue = mergeQueue(this.queue, session.queue);
    }
    if (this.offerChildIds().includes(session.sessionId)) this.childChanged(session.sessionId);
    // The picker lists every session, so a change elsewhere still needs a snapshot.
    this.emit("session changed");
  }

  private applyPermission(message: any): void {
    const permission = permissionFromMessage(message, this.selectedSessionId ?? "");
    if (!permission) return;
    if (permission.groupId && this.permissions.state.supported) {
      this.groupedPermissions.set(permission.permissionId, permission);
      return;
    }
    this.pendingPermission = permission;
    this.emit("permission");
  }

  /// A live event's stamp, to tell the session's clock from this computer's.
  private observeClock(sessionId: unknown, at: unknown): void {
    if (sessionId !== this.selectedSessionId || typeof at !== "number" || !(at > 0)) return;
    const offset = Date.now() - at;
    this.clockOffset = this.clockOffset === undefined ? offset : Math.min(this.clockOffset, offset);
  }

  private apply(event: EventRecord): void {
    if (!event?.seq || event.sessionId !== this.selectedSessionId || event.seq <= this.lastSeq) return;
    this.events.push(event);
    this.lastSeq = event.seq;
    this.firstSeq = this.firstSeq === undefined ? event.seq : Math.min(this.firstSeq, event.seq);
    this.reduce(event);
    this.emitInFrame(event.kind);
  }

  /// Snapshots before the next display frame, once for every event that lands before it.
  private emitInFrame(connection: string): void {
    const schedule = AcpmuxDirectClient.scheduleFrame;
    if (!schedule) return this.emit(connection);
    const scheduled = this.frameSnapshot !== undefined;
    this.frameSnapshot = connection;
    if (scheduled) return;
    schedule(() => {
      const pending = this.frameSnapshot;
      if (pending !== undefined && !this.closed) this.emit(pending);
    });
  }

  private rebuild(): void {
    const previous = new Map(this.rows);
    // A prompt still in flight keeps its optimistic row until an event settles it; a failed one stays to show it was not sent.
    const inFlight = new Set(this.optimisticPromptRows.values());
    // Those rows keep their place in the order.
    this.rows.retain((row) => row.failed === true || inFlight.has(row.id));
    this.waitingSteers = [];
    this.firstSeq = undefined;
    this.lastSeq = 0;
    this.turnOpen = false;
    this.streamingAssistant = undefined;
    this.streamingAssistantMessageId = undefined;
    this.streamingActivity = undefined;
    this.supersededMessageIds.clear();
    this.messageRows.clear();
    this.offerRows.clear();
    this.receivedOffers.clear();
    this.toolRows.clear();
    this.planCalls.clear();
    this.subagents = new SubagentFold();
    this.pendingPermission = undefined;
    this.pendingSecret = undefined;
    const through = this.replayThrough ?? Number.POSITIVE_INFINITY;
    const events = this.events.filter((event) => event.seq <= through).sort((a, b) => a.seq - b.seq);
    for (const event of events) {
      this.lastSeq = Math.max(this.lastSeq, event.seq);
      this.firstSeq = this.firstSeq === undefined ? event.seq : Math.min(this.firstSeq, event.seq);
      this.reduce(event);
    }
    // Rows kept from before (a prompt that failed or still sends) are newer than every replayed event.
    this.rows.placeLocalLast();
    this.rows.keepSame(previous);
  }

  /// rebuild() replays a partial event window, so keep the live summary, queue and
  /// permission; events after replayAfterSeq are then reapplied on top of them.
  private rebuildKeepingLiveState(replayAfterSeq?: number): void {
    const summary = this.summary;
    const queue = this.queue;
    const permission = this.pendingPermission;
    const secret = this.pendingSecret;
    this.rebuild();
    this.summary = summary;
    this.queue = queue;
    this.pendingPermission = permission;
    this.pendingSecret = secret;
    if (replayAfterSeq !== undefined)
      for (const event of this.events)
        if (event.seq > replayAfterSeq && event.dir === "mux") this.reduceLiveState(event);
  }

  /// Mux events that move the live summary, queue or permission.
  private reduceLiveState(event: EventRecord): void {
    const msg = event.msg ?? {};
    if (event.kind === "queue_updated") {
      // An edit keeps the prompt's place.
      const id = String(msg.promptId ?? "");
      this.queue = this.queue.map((entry) =>
        entry.id === id ? queuedEntry(id, String(msg.text ?? ""), entry.next === true) : entry,
      );
    } else if (event.kind === "queue_order" && Array.isArray(msg.order)) {
      const at = new Map(msg.order.map((id: unknown, index: number) => [String(id), index]));
      // A prompt sent now goes first and stops the turn: only the last one sent now is next.
      const next = msg.next === true ? String(msg.promptId ?? "") : undefined;
      if (next) this.sentNow.add(next);
      this.queue = [...this.queue]
        .sort((a, b) => (at.get(a.id) ?? at.size) - (at.get(b.id) ?? at.size))
        .map((entry) => (next === undefined ? entry : queuedEntry(entry.id, entry.prompt, entry.id === next)));
    } else if (event.kind === "queued") {
      const id = String(msg.promptId ?? "");
      // A task's result waiting behind the turn draws its received line now (offer/SuggestedTasks.tsx).
      if (this.queuedResult(msg, event.at)) return;
      if (id)
        this.queue = [...this.queue.filter((entry) => entry.id !== id), queuedEntry(id, String(msg.text ?? ""), false)];
      // acpmux took a prompt that waits behind the turn: its queue row shows it now, and the
      // composer is free for the next one.
      if (id && this.optimisticPromptRows.has(id)) {
        settleOptimisticPrompt(this.rows, this.optimisticPromptRows, msg);
        this.optimisticPromptTexts.delete(id);
        this.queuedSends.add(id);
        this.promptAccepts.get(id)?.();
      }
    } else if (event.kind === "queue_removed" || event.kind === "dequeued")
      this.queue = this.queue.filter((entry) => entry.id !== String(msg.promptId ?? ""));
    else if (event.kind === "permission_request") {
      this.openQuestions.add(String(msg.permissionId ?? `permission-${event.seq}`));
      this.markAwaitingPermission(msg.request?.toolCall?.toolCallId);
      this.applyPermission({ ...msg, sessionId: event.sessionId });
    } else if (event.kind === "permission_decision") {
      if (msg.permissionId) this.groupedPermissions.delete(String(msg.permissionId));
      else this.groupedPermissions.clear();
      if (msg.permissionId) this.openQuestions.delete(String(msg.permissionId));
      else this.openQuestions.clear();
      if (!msg.permissionId || this.pendingPermission?.permissionId === msg.permissionId)
        this.pendingPermission = this.permissions.state.supported
          ? undefined
          : [...this.groupedPermissions.values()].at(-1);
    } else if (event.kind === "secret_request")
      this.pendingSecret = {
        secretId: String(msg.secretId ?? ""),
        name: String(msg.name ?? ""),
        reason: String(msg.reason ?? ""),
      };
    else if (event.kind === "secret_decision") {
      if (this.pendingSecret?.secretId === msg.secretId) this.pendingSecret = undefined;
    } else if (event.kind === "permission_group" || event.kind === "permission_chat_allowance")
      void this.permissions.refresh().catch(() => {});
    else if (event.kind === "status") this.summary = { ...this.summary, status: msg.status };
  }

  /// A turn event newer than Stop ends its grace and its give-up.
  private stopAnswered(event: EventRecord): void {
    if (this.stopAfterSeq === undefined || event.seq <= this.stopAfterSeq) return;
    clearTimeout(this.stopTimer);
    this.stopGaveUp = false;
    this.stopAfterSeq = undefined;
  }

  private reduce(event: EventRecord): void {
    this.rows.current = event.seq;
    try {
      this.reduceEvent(event);
    } finally {
      this.rows.current = undefined;
      if (event.seq) this.rows.saw(event.seq);
    }
  }

  private reduceEvent(event: EventRecord): void {
    const msg = event.msg ?? {};
    const update = sessionUpdate(event);
    if (update?.sessionUpdate === USAGE_KIND) {
      const used = Number(update.used);
      const size = Number(update.size);
      if (Number.isFinite(used) && Number.isFinite(size) && size > 0) this.usage = { used, size };
      return;
    }
    if (update?.sessionUpdate === CONFIG_KIND) {
      // The event at attach's own lastSeq may be newer than the options it names (acpmux numbers the
      // event before it writes them): only events before it are history.
      if (!Array.isArray(update.configOptions) || (event.seq && event.seq < this.configSeq)) return;
      this.summary = { ...this.summary, configOptions: update.configOptions };
      if (event.seq) this.configSeq = event.seq;
      return;
    }
    // Claude Code names its version and model on every turn's init line: one row, where the
    // session first said so, that a later line with other facts (a restart on a new version, a
    // model switch) updates in place.
    const start =
      update?.sessionUpdate === SESSION_INFO_KIND
        ? sessionStartOf(update, { harness: this.summary?.harness, cwd: this.summary?.cwd })
        : undefined;
    if (start) {
      const existing = this.rows.get(SESSION_START_ROW);
      if (sameSessionStart(existing?.sessionStart, start)) return;
      this.rows.set(SESSION_START_ROW, {
        id: SESSION_START_ROW,
        version: (existing?.version ?? 0) + 1,
        at: existing?.at ?? event.at,
        seq: existing?.seq ?? event.seq,
        kind: "sessionStart",
        sessionStart: start,
      });
      return;
    }
    if (event.dir === "mux") {
      if (event.kind === BOOKMARKS_KIND) {
        // Another pane (or the TUI) marked a prompt: the minimap shows acpmux's marks.
        bookmarksHeard(event.sessionId ?? this.selectedSessionId, event.msg?.bookmarks);
      } else if (event.kind === "forked") {
        this.forkedAtSeq = event.seq;
      } else if (event.kind === "failover") {
        // acpmux moved the chat to its fallback harness (`hub/turns.rs`); the turn goes on there.
        if (typeof msg.from === "string" && typeof msg.to === "string") {
          this.endAssistantSegment();
          this.streamingActivity = undefined;
          const id = `failover-${event.seq}`;
          this.rows.set(id, {
            id,
            version: 1,
            at: event.at,
            kind: "failover",
            failover: { from: msg.from, to: msg.to },
          });
        }
      } else if (event.kind === "session_offer") {
        // Off by default: off, an offer draws nothing (offer/offersShown.ts).
        const offer = offersShown() ? sessionOffer(msg) : undefined;
        if (offer) this.addOffer(offer, event.at);
      } else if (event.kind === "session_offer_decision") {
        this.answerOffer(msg);
      } else if (event.kind === "user_message") {
        // A prompt, or a steer (which starts no turn but splits it), starts a new checklist.
        this.planRow = undefined;
        const promptId = typeof msg.promptId === "string" ? msg.promptId : undefined;
        const text = typeof msg.text === "string" ? msg.text : undefined;
        const fallbackPromptId =
          promptId ??
          (text ? [...this.optimisticPromptTexts.entries()].find(([, value]) => value === text)?.[0] : undefined);
        settleOptimisticPrompt(this.rows, this.optimisticPromptRows, {
          ...msg,
          promptId: fallbackPromptId,
        });
        if (fallbackPromptId) {
          this.optimisticPromptTexts.delete(fallbackPromptId);
          this.promptAccepts.get(fallbackPromptId)?.();
          // A prompt the pane put in the queue that ran at once (the turn ended meanwhile).
          if (this.queue.some((entry) => entry.id === fallbackPromptId))
            this.queue = this.queue.filter((entry) => entry.id !== fallbackPromptId);
        }
        this.subagents.closeBatch();
        // An agent reads a steer once the reply it writes ends (Claude Code): the rest of that
        // reply still streams after the steer's row and stays in its row above it, and the next
        // message's text starts below (cx-f51kv). Without message ids that end cannot be told.
        if (msg.steer !== true || !this.streamingAssistantMessageId) this.endAssistantSegment();
        // A call id names a call within its prompt: an adapter that numbers calls per process
        // reuses one in a later prompt, whose call draws under that prompt (cx-jzhka). A steer
        // splits a turn whose calls may still update.
        if (msg.steer !== true) {
          this.toolRows.clear();
          this.planCalls.clear();
        }
        this.streamingActivity = undefined;
        const received = offersShown() ? offerResult(msg) : undefined;
        // Its queued line, if the result waited, gives way to this prompt's.
        if (received) this.rows.delete(`received-${received.offerId}`);
        if (received) this.receivedOffers.add(received.offerId);
        // A newer prompt means any steer before it was read; a second steer can come in the same step.
        if (msg.steer !== true) this.landSteer();
        const steer = msg.steer === true ? "waiting" : promptId && this.sentNow.has(promptId) ? "stopped" : undefined;
        if (steer === "waiting") this.waitingSteers.push({ rowId: `user-${event.seq}`, promptId });
        this.rows.set(`user-${event.seq}`, {
          id: `user-${event.seq}`,
          version: 1,
          at: event.at,
          kind: "user",
          text: String(msg.text ?? ""),
          ...(received ? { received } : {}),
          ...(steer ? { steer } : {}),
          ...(promptImages(msg.images).length > 0 && { images: promptImages(msg.images) }),
          ...(fallbackPromptId && this.optimisticPromptAttachments.get(fallbackPromptId)?.length
            ? { retryAttachments: this.optimisticPromptAttachments.get(fallbackPromptId) }
            : {}),
        });
        if (fallbackPromptId) {
          const attachments = this.optimisticPromptAttachments.get(fallbackPromptId);
          if (attachments?.length) this.retryAttachments.set(`user-${event.seq}`, attachments);
          this.optimisticPromptAttachments.delete(fallbackPromptId);
        }
        this.turnOpen = true;
      } else if (event.kind === "turn_started") {
        this.turnOpen = true;
        this.settleCompactions(event.seq);
        // A Stop before this turn never judges it.
        this.stopAnswered(event);
        this.rows.set("typing", { id: "typing", version: 1, at: event.at, kind: "typing" });
      } else if (event.kind === "message_superseded") {
        const oldMessageId = typeof msg.oldMessageId === "string" ? msg.oldMessageId : undefined;
        if (oldMessageId) {
          applySupersededMessage(this.rows, this.messageRows, this.supersededMessageIds, oldMessageId);
          if (this.streamingAssistantMessageId === oldMessageId) {
            this.streamingAssistant = undefined;
            this.streamingAssistantMessageId = undefined;
          }
        }
      } else if (event.kind === "turn_end" || event.kind === "turn_result") {
        this.turnOpen = false;
        this.settleCompactions(event.seq);
        this.landSteer();
        // Stop was answered: its grace must not judge the next turn.
        this.stopAnswered(event);
        this.pendingPermission = undefined;
        this.groupedPermissions.clear();
        this.openQuestions.clear();
        this.heldEdits.clear();
        // A new row, never an in-place change: emitted snapshots share row objects, and the
        // transcript's memo compares the drawn row's version with the next one.
        this.endAssistantSegment();
        this.rows.delete("typing");
        const checkpoint = event.kind === "turn_result" ? readSummaryCheckpoint(msg) : undefined;
        if (event.kind === "turn_result")
          this.rows.set(`summary-${event.seq}`, {
            id: `summary-${event.seq}`,
            version: 1,
            at: event.at,
            kind: "turnSummary",
            seq: event.seq,
            ...this.turnTotals(event.at),
            status: String(msg.status ?? "completed"),
            error: msg.errorText,
            ...(checkpoint ? { checkpoint } : {}),
          });
        // acpmux ended a turn whose agent did not answer Stop (`hub/cancel.rs`). After the summary, so its fold never hides it.
        if (event.kind === "turn_result" && msg.cancelForced === true)
          this.rows.set(`notice-stop-${event.seq}`, {
            id: `notice-stop-${event.seq}`,
            version: 1,
            at: event.at,
            kind: "notice",
            text: translate("stop.forced"),
          });
        this.streamingAssistant = undefined;
        this.streamingAssistantMessageId = undefined;
        this.streamingActivity = undefined;
      } else this.reduceLiveState(event);
      return;
    }
    if (!update) return;
    if (this.subagents.reduce(event, update)) {
      for (const row of this.subagents.takeRows()) {
        // A new group ends the text and tool calls before it, like a tool call does.
        if (!this.rows.has(row.id)) {
          this.endAssistantSegment();
          this.streamingActivity = undefined;
        }
        this.rows.set(row.id, row);
      }
      return;
    }
    const commands = commandsFromUpdate(update);
    if (commands) {
      this.commands = commands;
      this.commandsApplied = true;
      return;
    }
    const text = textFromContent(update.content);
    if (event.kind === "agent_message_chunk" && text) {
      acpmuxPerf.markAgent("firstToken");
      // Subagents spawned after the session's own text form a new group.
      this.subagents.closeBatch();
      const messageId = typeof update.messageId === "string" ? update.messageId : undefined;
      if (messageId && this.supersededMessageIds.has(messageId)) return;
      const sameMessage = Boolean(
        this.streamingAssistant &&
        (!messageId || !this.streamingAssistantMessageId || this.streamingAssistantMessageId === messageId),
      );
      const id = sameMessage ? this.streamingAssistant! : `assistant-${event.seq}`;
      // A message after the reply that was streaming when the steer went: the agent read it.
      if (!sameMessage) this.landSteer();
      const existing = this.rows.get(id);
      // Text after tool calls is a new segment; the next tool call opens a new fold.
      this.streamingActivity = undefined;
      this.rows.set(id, {
        id,
        version: (existing?.version ?? 0) + 1,
        at: existing?.at ?? event.at,
        kind: "assistant",
        text: `${existing?.text ?? ""}${text}`,
        streaming: true,
      });
      this.streamingAssistant = id;
      this.streamingAssistantMessageId = messageId;
      if (messageId) {
        const ids = this.messageRows.get(messageId) ?? [];
        if (!ids.includes(id)) this.messageRows.set(messageId, [...ids, id]);
      }
      this.rows.delete("typing");
    } else if (event.kind === "agent_thought_chunk" && text) {
      this.landSteer();
      this.endAssistantSegment();
      const id = this.streamingActivity ?? `activity-${event.seq}`;
      const existing = this.rows.get(id);
      this.rows.set(id, {
        id,
        version: (existing?.version ?? 0) + 1,
        at: existing?.at ?? event.at,
        kind: "activity",
        toolCount: existing?.toolCount ?? 0,
        items: appendThought(existing?.items ?? [], text, event.at),
      });
      this.streamingActivity = id;
    } else if (event.kind === "tool_call" || event.kind === "tool_call_update") {
      const callId = String(update.toolCallId ?? `tool-${event.seq}`);
      const tool = update._meta?.claude?.tool ?? update.title;
      if (event.kind === "tool_call" && tool === "TodoWrite" && this.planRow) this.planCalls.add(callId);
      if (this.planCalls.has(callId)) return;
      // An update to a call already shown stays in its fold; a new call ends the text segment.
      const known = this.toolRows.get(callId);
      const knownRow = known && this.rows.has(known) ? known : undefined;
      if (!knownRow) this.endAssistantSegment();
      const id = knownRow ?? this.streamingActivity ?? `activity-${event.seq}`;
      const existing = this.rows.get(id);
      const items = [...(existing?.items ?? [])];
      const itemIndex = items.findIndex((item) => item.tool?.id === callId);
      const item = this.holdEdit(
        mergeToolItem(itemIndex >= 0 ? items[itemIndex] : undefined, update, callId, text, event.at),
        event.kind === "tool_call",
      );
      if (itemIndex >= 0) items[itemIndex] = item;
      else items.push(item);
      this.rows.set(id, {
        id,
        version: (existing?.version ?? 0) + 1,
        at: existing?.at ?? event.at,
        kind: "activity",
        toolCount: items.filter((entry) => entry.kind === "tool").length,
        items,
      });
      this.toolRows.set(callId, id);
      if (!knownRow) this.streamingActivity = id;
    } else if (event.kind === "background_task_update") {
      const task = backgroundTask(update);
      if (!task) return;
      // Noted where it ended: the text and tool fold before it close, as a tool call's would.
      this.endAssistantSegment();
      this.streamingActivity = undefined;
      const id = `bgtask-${event.seq}`;
      this.rows.set(id, {
        id,
        version: 1,
        at: event.at,
        kind: "backgroundTask",
        backgroundTask: task,
      });
    } else if (event.kind === "compaction") {
      const compaction = compactionOf(update);
      if (!compaction) return;
      // A note between messages: the text and tool fold before it close.
      this.endAssistantSegment();
      this.streamingActivity = undefined;
      // One row per compaction: its end replaces the latest running note before it, or the
      // latest one its turn's end noted as failed (a Stop acpmux forced while the compaction
      // went on: its end comes after the turn's). A running note always starts its own row, and
      // an older history page binds to its own rows, never to a live one.
      let running: AcpmuxRow | undefined;
      if (compaction.state !== "running")
        for (const row of this.rows.values())
          if (
            row.kind === "compaction" &&
            (row.compaction?.state === "running" || row.compaction?.inferred === true) &&
            (row.seq ?? 0) < event.seq &&
            (row.seq ?? 0) > (running?.seq ?? -1)
          )
            running = row;
      const id = running?.id ?? `compaction-${event.seq}`;
      this.rows.set(id, {
        id,
        version: (running?.version ?? 0) + 1,
        at: running?.at ?? event.at,
        seq: running?.seq ?? event.seq,
        kind: "compaction",
        compaction,
      });
    } else if (event.kind === "plan") {
      const plan = planEntries(update.entries);
      const existing = this.planRow ? this.rows.get(this.planRow) : undefined;
      // A cleared list (TodoWrite with no todos, Codex's empty plan) takes the checklist away.
      if (Array.isArray(update.entries) && plan.length === 0) {
        if (existing) this.rows.delete(existing.id);
        this.planRow = undefined;
        return;
      }
      // A new checklist ends the text and tool fold before it, as the call it stands for would.
      if (!existing) {
        this.endAssistantSegment();
        this.streamingActivity = undefined;
      }
      const id = existing ? existing.id : `plan-${event.seq}`;
      this.planRow = id;
      this.rows.set(id, {
        id,
        version: (existing?.version ?? 0) + 1,
        at: existing?.at ?? event.at,
        kind: "plan",
        ...(plan.length > 0 ? { plan } : { text: text || JSON.stringify(update.entries ?? update.content ?? "") }),
      });
    }
  }

  /// A call that asks before it runs waits on its permission ("pending") until it completes or
  /// fails: Claude sends a proposed edit, diff included, before it asks, and it is not an edit yet.
  private markAwaitingPermission(callId: unknown): void {
    if (callId != null) this.heldEdits.add(String(callId));
    const id = callId == null ? undefined : this.toolRows.get(String(callId));
    const row = id ? this.rows.get(id) : undefined;
    if (!row) return;
    const items = (row.items ?? []).map((item) =>
      item.tool?.id === String(callId) && item.tool.status === "in_progress"
        ? { ...item, tool: { ...item.tool, status: "pending" } }
        : item,
    );
    this.rows.set(row.id, { ...row, version: row.version + 1, items });
  }

  /// `item` as the transcript shows it: an edit that waits on a permission question stays
  /// "pending". Claude asks one question at a time, so an edit that arrives while another's
  /// question is open sends its diff before its own question, and waits too.
  private holdEdit(item: AcpmuxActivity, isNew: boolean): AcpmuxActivity {
    const tool = item.tool;
    if (!tool) return item;
    if (tool.status === "completed" || tool.status === "failed") {
      this.heldEdits.delete(tool.id);
      return item;
    }
    const isEdit = tool.kind === "edit" || tool.kind === "fileChange";
    if (isNew && isEdit && this.openQuestions.size > 0) this.heldEdits.add(tool.id);
    if (!this.heldEdits.has(tool.id) || tool.status === "pending") return item;
    return { ...item, tool: { ...tool, status: "pending" } };
  }

  /// The tool calls and time since the turn's user message. A prompt still sending (queued
  /// behind this turn) or one that failed to send did not start a turn.
  private turnTotals(endedAt: number): { durationMs?: number; toolCount: number } {
    // An older page's turn ends below the held rows: its own prompt is the last one before them.
    const below = this.foldingBelow;
    const rows = this.rows
      .sorted()
      .filter((row) => !row.pending && !row.failed && (below === undefined || this.rows.orderOf(row.id) < below));
    let start = rows.length;
    while (start > 0 && rows[start - 1]!.kind !== "user") start -= 1;
    const user = rows[start - 1];
    const toolCount = rows
      .slice(start)
      .reduce((sum, row) => sum + (row.kind === "activity" ? (row.toolCount ?? 0) : 0), 0);
    return { durationMs: user ? Math.max(0, endedAt - user.at) : undefined, toolCount };
  }

  /// Closes the assistant text being streamed, so later text starts a new row below.
  /// The waiting steers (or the one `promptId` names) were read: their rows say so.
  private landSteer(promptId?: string): void {
    const read = this.waitingSteers.filter((waiting) => promptId === undefined || waiting.promptId === promptId);
    if (!read.length) return;
    this.waitingSteers = this.waitingSteers.filter((waiting) => !read.includes(waiting));
    for (const waiting of read) {
      const row = this.rows.get(waiting.rowId);
      if (row?.steer === "waiting") this.rows.set(row.id, { ...row, version: row.version + 1, steer: "landed" });
    }
  }

  /// A compaction still running when its turn ends (a Stop, the agent process exiting, a
  /// relaunch) or the next turn starts may never send how it ended: it is noted as failed, so
  /// the row stops spinning, live and when the history is read again. `inferred` lets an end
  /// that does come later (a forced Stop the compaction outlived) take the row back.
  private settleCompactions(seq: number) {
    for (const row of this.rows.values())
      if (row.kind === "compaction" && row.compaction?.state === "running" && (row.seq ?? 0) < seq)
        this.rows.set(row.id, {
          ...row,
          version: row.version + 1,
          compaction: { ...row.compaction, state: "failed", inferred: true },
        });
  }

  private endAssistantSegment(): void {
    if (!this.streamingAssistant) return;
    const row = this.rows.get(this.streamingAssistant);
    if (row) this.rows.set(row.id, { ...row, version: row.version + 1, streaming: false });
    this.streamingAssistant = undefined;
    this.streamingAssistantMessageId = undefined;
  }

  private emit(connection = "connected"): void {
    acpmuxPerf.timed("client.emit", () => this.emitNow(connection));
  }

  private emitNow(connection: string): void {
    if (this.snapshotHold) {
      this.snapshotHold.connection = connection;
      return;
    }
    // This snapshot carries every event so far, so a snapshot waiting for the frame has nothing left.
    this.frameSnapshot = undefined;
    const summary = this.summary;
    const effort = (summary?.configOptions ?? []).find(
      (option: any) => option.category === "thought_level" || option.id === "reasoning_effort",
    );
    this.listener({
      type: "snapshot",
      protocolVersion: 1,
      rows: this.rows.sorted(),
      subagentViews: this.subagents.views(),
      sessions: this.sessions.map((session) => {
        let entry = this.sessionEntries.get(session);
        if (!entry) {
          entry = sessionEntry(session);
          this.sessionEntries.set(session, entry);
        }
        return entry;
      }),
      peers: this.peers,
      ...(this.forkedAtSeq !== undefined ? { forkedAtSeq: this.forkedAtSeq } : {}),
      summary: summary
        ? {
            sessionId: summary.sessionId,
            cwd: summary.cwd,
            turnCount: summary.turnCount,
            usage: this.usage,
            host: text(summary.host),
            peer: text(summary.peer),
            hostKind: hostKind(summary.hostKind),
            branch: text(summary.branch),
            worktree: text(summary.worktree),
            title: summary.title,
            name: summary.name,
            harness: summary.harness,
            family: typeof summary.family === "string" ? summary.family : undefined,
            // acpmux reports `model: null` for a harness with no model (one known only from its config).
            model: text(summary.model),
            effort: effort?.currentValue,
            // `audio` only while the picked model hears it (takesAudio).
            promptCapabilities: summary.agentCapabilities?.promptCapabilities && {
              ...summary.agentCapabilities.promptCapabilities,
              audio: takesAudio(summary.agentCapabilities.promptCapabilities, summary.configOptions),
            },
            steering: summary.steering === true,
            queuePaused: summary.queuePaused === true,
            ...(Array.isArray(summary.mcpServers) ? { mcpServers: summary.mcpServers } : {}),
            status: summary.status,
            enforcement: sessionEnforcement(summary.enforcement),
            modes: summary.modes,
            configOptions: summary.configOptions,
          }
        : undefined,
      connection,
      origin: this.origin,
      ...(this.listedSessions ? { listedSessions: true as const } : {}),
      ...(this.extensions.includes("acp.trust.set") ? { answersTrust: true } : {}),
      sessionId: this.selectedSessionId,
      // A replayed turn is history: no live "Working for" clock.
      isWorking:
        this.replayThrough === undefined && !this.stopGaveUp && (this.turnOpen || summary?.status === "running"),
      // Only a peer runs on another clock; this computer's own sessions need no correction.
      ...(summary?.peer && this.clockOffset !== undefined ? { clockOffsetMs: this.clockOffset } : {}),
      canFork: this.canFork,
      canHandoff: this.handoffSupported,
      handoff: this.handoff.state,
      permissionGroups: this.permissions.state,
      queue: this.shownQueue(),
      permission: this.pendingPermission,
      secret: this.pendingSecret,
      catalog: [],
      commands: this.commands,
      canLoadOlder: !this.historyExhausted && (this.firstSeq ?? 1) > 1,
      missingSession: this.selectedSessionId ? undefined : this.missingSession,
      liveChat: this.liveAdopt && {
        canFork: this.liveAdopt.canFork,
        command: this.liveAdopt.command,
      },
    });
  }

  snapshot(): void {
    this.emit();
  }
  /** The session this pane shows, if any. */
  get selectedSession(): string | undefined {
    return this.selectedSessionId;
  }
  /** A copy of the selected session's recorded events, oldest first, for the inspector. */
  sessionEvents(): EventRecord[] {
    return this.events.slice();
  }
  /** A new chat starting (`create`): a Send meanwhile waits for it and goes to the new chat, not to
   *  the session still on screen (a harness pick), and a Send with no session joins it. */
  private creating?: Promise<string | undefined>;
  async ensureSession(): Promise<string | undefined> {
    // A failed start leaves the selection as it was; the prompt then goes where the pane is.
    if (this.creating) await this.creating.catch(() => undefined);
    if (!this.selectedSessionId) await this.create();
    return this.selectedSessionId;
  }

  /// Starts one live agent child for each of the most recent project sessions whose folder an
  /// agent may use unasked (`isWarmableCwd`).
  /// Old daemons simply reject this extension, so warming never blocks chat.
  async warmRecentProjects(limit = 3): Promise<void> {
    const ids: string[] = [];
    const seen = new Set<string>();
    for (const session of [...this.sessions].sort((a, b) => Number(b.updatedAt ?? 0) - Number(a.updatedAt ?? 0))) {
      const cwd = typeof session.cwd === "string" ? session.cwd : "";
      // Never the home folder or a privacy-protected one (warmFolders.ts).
      if (!cwd || seen.has(cwd) || !isWarmableCwd(cwd)) continue;
      seen.add(cwd);
      ids.push(session.sessionId);
      if (ids.length >= limit) break;
    }
    if (!ids.length) return;
    await this.request("_acpmux/warm", { sessionIds: ids, limit }).catch(() => undefined);
  }
  /// Sends a prompt. `promptId` keys its optimistic row (`local-<promptId>`), so a prompt the
  /// pane drew while a harness started keeps its row once it goes out (harnessSwitch.ts).
  /// `accepted` runs once acpmux took the prompt (its echo or its reply); a refusal comes before
  /// that, and then a caller that passed `accepted` still holds the prompt (the composer keeps
  /// it), so the prompt leaves no bubble and the refusal names its reason in the transcript.
  /// `ticket`: the gesture a send kept for this prompt while acpmux held it for the folder trust
  /// answer (heldPrompt.ts); it rides as `_meta.cmuxGesture`, and the host strips it.
  /// `steer`: into the running turn now, and an agent that cannot steer stops the turn and
  /// takes it next (`_meta.acpmux.interrupt`); otherwise it waits behind the turn.
  async send(
    input: string,
    attachments: ComposerAttachment[] = [],
    promptId: string = crypto.randomUUID(),
    accepted?: () => void,
    ticket?: string,
    steer = false,
  ): Promise<string | undefined> {
    const record = this.handoff.state.record;
    if (
      this.handoffSupported &&
      this.selectedSessionId &&
      (!this.handoff.state.ready ||
        (record?.target.sessionId === this.selectedSessionId &&
          record.state !== "started" &&
          record.state !== "discarded" &&
          !this.handoff.state.receipt))
    )
      throw new Error(translate("error.reviewContinuation"));
    // A shown session takes the prompt in this task, so its row draws in the frame of the send;
    // while a new chat starts, the prompt waits for it (ensureSession).
    const shown = this.creating ? undefined : this.selectedSessionId;
    const sessionId = shown ?? (await this.ensureSession());
    if (!sessionId) return undefined;
    const text = promptText(input, attachments);
    const rowId = `local-${promptId}`;
    const at = Date.now();
    this.optimisticPromptRows.set(promptId, rowId);
    this.optimisticPromptTexts.set(promptId, text);
    if (attachments.length) this.optimisticPromptAttachments.set(promptId, attachments);
    // A prompt behind the shown chat's running turn waits in the queue: it shows there from the
    // send on, never first as a transcript bubble that acpmux's `queued` record then moves.
    const waits = !steer && shown === sessionId && this.turnOpen;
    const generation = this.selectionGeneration;
    if (waits)
      this.queue = [...this.queue.filter((entry) => entry.id !== promptId), queuedEntry(promptId, text, false)];
    else this.rows.set(rowId, { id: rowId, version: 1, at, kind: "user", text, pending: true });
    let taken = false;
    // The chat's first prompt carries its workspace context, once: a prompt acpmux took used it,
    // and a prompt sent while one carrying it is in flight goes without it.
    const context = this.host.workspaceContext && !this.contextInFlight ? WORKSPACE_CONTEXT : undefined;
    if (context) this.contextInFlight = true;
    const accept = () => {
      this.promptAccepts.delete(promptId);
      if (taken) return;
      taken = true;
      if (context) this.host = { ...this.host, workspaceContext: undefined };
      accepted?.();
    };
    this.promptAccepts.set(promptId, accept);
    this.emit();
    try {
      await this.request("session/prompt", {
        sessionId,
        // A recording goes only to a harness that takes voice input; one moved to another
        // harness (a switch, a held prompt put back) goes as its transcript.
        prompt: promptBlocks(
          input,
          takesAudio(this.summary?.agentCapabilities?.promptCapabilities, this.summary?.configOptions)
            ? attachments
            : attachments.filter((attachment) => attachment.kind !== "audio"),
        ),
        _meta: {
          acpmux: {
            promptId,
            ...(steer ? { steer: true, interrupt: true } : {}),
            ...(context ? { context } : {}),
          },
          ...(ticket ? { cmuxGesture: ticket } : {}),
        },
      });
      accept();
      // A steer's answer comes once the agent read it (Claude Code's `steered`) or its turn ended.
      if (
        steer &&
        this.selectedSessionId === sessionId &&
        this.waitingSteers.some((waiting) => waiting.promptId === promptId)
      ) {
        this.landSteer(promptId);
        this.emit();
      }
      // Ran or withdrawn: what it held for its bubble and queue row is done with.
      if (this.queue.some((entry) => entry.id === promptId))
        this.queue = this.queue.filter((entry) => entry.id !== promptId);
      this.queuedSends.delete(promptId);
      this.optimisticPromptAttachments.delete(promptId);
    } catch (error) {
      this.promptAccepts.delete(promptId);
      // A refused prompt did not use the context: the next send carries it.
      if (context && !taken) this.contextInFlight = false;
      // A queued prompt refused when its turn came gets its bubble back, to fail with Retry.
      const queued = this.queuedSends.delete(promptId);
      // Only into the chat it was sent in, still shown: its Retry sends there.
      const here = generation === this.selectionGeneration && this.selectedSessionId === sessionId;
      if (here && (queued || waits)) {
        this.queue = this.queue.filter((entry) => entry.id !== promptId);
        this.optimisticPromptRows.set(promptId, rowId);
        this.rows.set(rowId, { id: rowId, version: 1, at, kind: "user", text, pending: true });
      }
      const code = (error as { code?: unknown } | null)?.code;
      const refused = typeof code === "string" && code.startsWith("transport.");
      // acpmux holds every prompt while the folder's trust question is open (`trust_gate.rs`), and
      // a sender that holds its prompt (`accepted`) keeps every refused one: the prompt never
      // went, so it leaves no bubble, and the pane keeps it in (or puts it back in) the composer.
      const held = !taken && accepted !== undefined;
      // The folder's trust question (the one route); the pane's sender adds the re-send.
      this.routeTrustRefusal(error);
      if ((isTrustRefusal(error) && !queued) || held) {
        this.rows.delete(rowId);
        this.optimisticPromptRows.delete(promptId);
        this.optimisticPromptTexts.delete(promptId);
        this.optimisticPromptAttachments.delete(promptId);
        // The prompt is still in the composer, so Enter sends it again (no Retry button). A refusal
        // for want of a real key or click (dictation's autoSend after a session ended by itself)
        // says just that, not the generic refusal's pick wording (cx-w2p8r).
        if (held && !isTrustRefusal(error))
          this.notice(
            code === "transport.gesture_required"
              ? translate("prompt.notSentAgain")
              : translate("prompt.notSent", { reason: errorMessage(error) }),
          );
        else this.emit();
        throw error;
      }
      const row = this.rows.get(rowId);
      if (row) {
        // A new row object: the transcript's rows are memoized on identity and version. The
        // bubble says why it got no reply; a refusal for want of a gesture asks for Retry.
        this.rows.set(rowId, {
          ...row,
          pending: false,
          failed: true,
          error:
            code === "transport.gesture_required"
              ? translate("prompt.notSentGesture")
              : translate("prompt.notSent", { reason: errorMessage(error) }),
          version: row.version + 1,
        });
        this.failedPrompts.set(rowId, { input, attachments });
      }
      this.optimisticPromptRows.delete(promptId);
      this.optimisticPromptTexts.delete(promptId);
      this.optimisticPromptAttachments.delete(promptId);
      // The host refused one frame and answered it: the connection is as it was.
      this.emit(refused ? undefined : "failed");
      throw error;
    }
    return sessionId;
  }

  /// Retry on a prompt that was not sent: its bubble goes and the same prompt is sent again.
  async retryPrompt(rowId: string): Promise<string | undefined> {
    const failed = this.failedPrompts.get(rowId);
    if (!failed) return undefined;
    this.failedPrompts.delete(rowId);
    this.rows.delete(rowId);
    this.emit();
    return this.send(failed.input, failed.attachments);
  }
  /// What to send again with prompt row `rowId` (Retry, Edit): the attachments this page sent, else
  /// its images read back from acpmux (a prompt sent before a reload, or from another window).
  async promptAttachments(rowId: string): Promise<ComposerAttachment[]> {
    const kept = this.retryAttachments.get(rowId);
    if (kept?.length) return kept;
    const images = this.rows.get(rowId)?.images ?? [];
    const read = await Promise.all(
      images.map(async (image, index): Promise<ComposerAttachment | undefined> => {
        const data = await this.promptImageData(image.id);
        if (!data) return undefined;
        return {
          id: `sent-${image.id}`,
          kind: "image",
          name: image.name ?? `image-${index + 1}`,
          mimeType: data.mimeType,
          size: Math.floor((data.data.length * 3) / 4),
          data: data.data,
        };
      }),
    );
    return read.filter((attachment): attachment is ComposerAttachment => attachment !== undefined);
  }
  /// The image `id` a prompt of the open chat sent, as a data URL; undefined when acpmux has none.
  /// An id names the image's bytes, so one read serves every bubble that shows it.
  async promptImage(id: string): Promise<string | undefined> {
    const shown = this.promptImageUrls.get(id);
    if (shown) return shown;
    const data = await this.promptImageData(id);
    const url = data && `data:${data.mimeType};base64,${data.data}`;
    if (url) this.promptImageUrls.set(id, url);
    return url;
  }
  private readonly promptImageUrls = new Map<string, string>();
  private async promptImageData(id: string): Promise<{ mimeType: string; data: string } | undefined> {
    const sessionId = this.selectedSession;
    if (!sessionId) return undefined;
    try {
      const reply = await this.request("_acpmux/attachment", { sessionId, id });
      return typeof reply?.data === "string"
        ? {
            mimeType: typeof reply.mimeType === "string" ? reply.mimeType : "image/png",
            data: reply.data,
          }
        : undefined;
    } catch {
      return undefined;
    }
  }
  async continueIn(harness: string): Promise<string | undefined> {
    if (!this.handoffSupported || this.turnOpen || this.summary?.status === "running" || this.queue.length > 0) return;
    const generation = this.selectionGeneration;
    const record = await this.handoff.prepare(harness);
    if (!record || generation !== this.selectionGeneration) return;
    return this.select(record.target.sessionId);
  }
  saveHandoff(review: HandoffReviewInput) {
    return this.handoff.save(review);
  }
  startHandoff(review: HandoffReviewInput) {
    return this.handoff.start(review);
  }
  async discardHandoff(): Promise<string | undefined> {
    const generation = this.selectionGeneration;
    const record = await this.handoff.discard();
    if (!record || generation !== this.selectionGeneration) return;
    return this.select(record.source.sessionId);
  }
  refreshHandoff() {
    return this.handoff.refresh();
  }
  async cancel(): Promise<void> {
    if (!this.selectedSessionId || !this.socket) return;
    const text = JSON.stringify({
      jsonrpc: "2.0",
      method: "session/cancel",
      params: { sessionId: this.selectedSessionId },
    });
    this.wire.sent(text, "session/cancel");
    this.socket.send(text);
    // Stop always frees the chat: a turn still open after the grace (acpmux ends one whose agent
    // ignores the cancel; an older one does not) stops showing as working, and the chat says so.
    const sessionId = this.selectedSessionId;
    const generation = this.selectionGeneration;
    clearTimeout(this.stopTimer);
    this.stopAfterSeq = this.lastSeq;
    this.stopTimer = setTimeout(() => {
      if (this.closed || generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return;
      if (!this.turnOpen && this.summary?.status !== "running") return;
      this.stopGaveUp = true;
      this.notice(translate("stop.forced"));
    }, STOP_GRACE_MS);
  }
  /// Withdraws a queued prompt before its turn starts; `removed` is false once it started.
  async removeQueued(promptId: string): Promise<{ removed: boolean }> {
    if (!this.selectedSessionId) return { removed: false };
    return this.request("_acpmux/queue_remove", { sessionId: this.selectedSessionId, promptId });
  }
  /// Archive has acpmux tag the selected chat `archived` (the lists hide it; acpmux values it with
  /// when); Unarchive removes the tag. The page sends it on its own connection (cx-jlzsf).
  async archive(archived: boolean): Promise<void> {
    const sessionId = this.selectedSessionId;
    if (!sessionId) throw new Error(translate("error.notOpen"));
    await this.request("_acpmux/archive", { sessionId, archived });
  }
  /// Mark as Unread (cx-ncc.78): acpmux keeps the selected chat unread until it is hidden and
  /// shown again.
  async markUnread(): Promise<void> {
    const sessionId = this.selectedSessionId;
    if (!sessionId) throw new Error(translate("error.notOpen"));
    await this.request("_acpmux/markUnread", { sessionId });
  }
  /// New side chat: acpmux tags the fork `sessionId` as a side chat of `chat` (the `side` tag),
  /// which keeps it off the lists (cx-jlzsf).
  async markSide(sessionId: string, chat: string): Promise<void> {
    await this.request("_acpmux/side", { sessionId, chat });
  }
  /// The shown chat's offer `offerId` (cx-807da), while its card is drawn.
  offer(offerId: string): AcpmuxSessionOffer | undefined {
    const row = this.rows.get(this.offerRows.get(offerId) ?? "");
    return row?.offers?.find((offer) => offer.offerId === offerId);
  }
  /// A `queued` record of a task's result (acpmux queues it when the chat is busy and its agent
  /// does not steer): one received line in the thread, never a queued prompt. False for others.
  private queuedResult(msg: any, at: number): boolean {
    const received = offersShown() ? offerResult(msg) : undefined;
    if (!received) return false;
    const id = `received-${received.offerId}`;
    if (!this.receivedOffers.has(received.offerId) && !this.rows.has(id))
      this.rows.set(id, {
        id,
        version: 1,
        at,
        kind: OFFER_RESULT,
        text: String(msg.text ?? ""),
        received,
      });
    return true;
  }
  /// The queue the composer shows: a task's result waiting there draws as its received line instead.
  private shownQueue(): { id: string; prompt: string }[] {
    if (!offersShown()) return this.queue;
    const shown = this.queue.filter((entry) => !entry.id.startsWith(OFFER_RESULT_PROMPT));
    return shown.length === this.queue.length ? this.queue : shown;
  }
  /// The `agent.suggestedTasks` Debug toggle turned on or off: offers draw or go at once.
  suggestedTasksChanged(): void {
    if (!this.selectedSessionId || this.events.length === 0) return;
    this.rebuildKeepingLiveState();
    this.emit();
  }
  /// Do it here on an offer (cx-lo9yf): acpmux records it answered `here`; the caller then sends
  /// the offer's prompt to this chat as the person's own.
  async offerHere(sessionId: string, offerId: string): Promise<void> {
    await this.request("_acpmux/offer_respond", { sessionId, offerId, outcome: "here" });
  }
  /// Dismiss on an offer's chip: acpmux records the answer, and its record closes the chip.
  async dismissOffer(sessionId: string, offerId: string): Promise<void> {
    await this.request("_acpmux/offer_respond", { sessionId, offerId, outcome: "dismissed" });
  }
  /// Start on an offer's chip: starts the offered chat in `cwd` on the offer's agent and model
  /// without showing it, answers the offer with it (acpmux makes `sessionId` its parent), then
  /// sends it the offer's prompt. A refused answer ends the new chat. Returns the new chat.
  async startOffer(sessionId: string, offer: AcpmuxSessionOffer, cwd: string): Promise<string> {
    const params = newSessionParams({ cwd }, offer.harness);
    if (offer.model) params.model = offer.model;
    // A trust question routes as any new chat's does; Trust starts the offer again.
    const again = () => void this.startOffer(sessionId, offer, cwd).catch(() => undefined);
    const child = (await this.newSession(params, again))?.sessionId;
    if (!child) throw new Error(translate("offer.failed"));
    try {
      await this.request("_acpmux/offer_respond", {
        sessionId,
        offerId: offer.offerId,
        outcome: "accepted",
        childSessionId: String(child),
      });
    } catch (error) {
      this.discard(String(child));
      throw error;
    }
    void this.promptUnseen(String(child), offer.prompt);
    return String(child);
  }
  /// Sends `text` to chat `sessionId`, which this pane does not show. acpmux attaches a prompt's
  /// sender to its chat, as a viewer, which would mark its turn seen: attached hidden first (for
  /// the tool calls its started row shows), the prompt adds nothing, and the attach ends with the
  /// turn (unless the pane shows it by then).
  private async promptUnseen(sessionId: string, text: string): Promise<void> {
    await this.offerChildren
      .prompting(sessionId, () =>
        // The reply comes when the turn ends; the chat shows how it goes.
        this.request("session/prompt", {
          sessionId,
          prompt: promptBlocks(text, []),
          _meta: { acpmux: { promptId: crypto.randomUUID() } },
        }),
      )
      // A prompt acpmux refused shows in the chat itself.
      .catch(() => undefined);
  }
  /// An offer the reducer draws: offers of one group share one card, in the order they came.
  private addOffer(offer: AcpmuxSessionOffer, at: number): void {
    const id = offer.groupId ? `offers-${offer.groupId}` : `offer-${offer.offerId}`;
    const row = this.rows.get(id);
    if (!row) {
      this.endAssistantSegment();
      this.streamingActivity = undefined;
    }
    const offers = [...(row?.offers ?? []).filter((item) => item.offerId !== offer.offerId), offer];
    this.offerRows.set(offer.offerId, id);
    this.rows.set(id, {
      id,
      version: (row?.version ?? 0) + 1,
      at: row?.at ?? at,
      kind: "sessionOffer",
      offers,
    });
  }
  /// A `session_offer_decision`: the offer's task is started, dismissed or done here.
  private answerOffer(msg: any): void {
    const offerId = String(msg.offerId ?? "");
    const id = this.offerRows.get(offerId);
    const row = id ? this.rows.get(id) : undefined;
    const outcome = ["accepted", "dismissed", "here"].includes(msg.outcome) ? msg.outcome : undefined;
    if (!id || !row?.offers || !outcome) return;
    const child = typeof msg.childSessionId === "string" ? { childSessionId: msg.childSessionId } : {};
    const offers = row.offers.map((offer) =>
      offer.offerId === offerId ? this.liveOffer({ ...offer, outcome, ...child }) : offer,
    );
    this.rows.set(id, { ...row, version: row.version + 1, offers });
    this.watchOfferChildren();
  }
  /// A started offer with its chat's status and latest tool call, as its row shows them.
  private liveOffer(offer: AcpmuxSessionOffer): AcpmuxSessionOffer {
    const { childStatus: _status, activity: _activity, ...rest } = offer;
    const child = rest.outcome === "accepted" ? rest.childSessionId : undefined;
    if (!child) return rest;
    const status = this.sessions.find((session) => session.sessionId === child)?.status;
    const activity = this.offerChildren.activity(child);
    return {
      ...rest,
      ...(typeof status === "string" ? { childStatus: status } : {}),
      ...(activity ? { activity } : {}),
    };
  }
  /// The chats started from the shown chat's offers.
  private offerChildIds(): string[] {
    return [...new Set(this.offerRows.values())].flatMap(
      (id) => this.rows.get(id)?.offers?.flatMap((offer) => (offer.childSessionId ? [offer.childSessionId] : [])) ?? [],
    );
  }
  /// Attaches to the started chats that run, for their rows' subtitles (offer/offerChildren.ts).
  private watchOfferChildren(): void {
    this.offerChildren.want(
      this.offerChildIds().map((child) => ({
        child,
        status: this.sessions.find((session) => session.sessionId === child)?.status,
      })),
    );
  }
  /// Chat `child`, started from an offer here, changed: its row redraws.
  private childChanged(child: string): void {
    for (const id of new Set(this.offerRows.values())) {
      const row = this.rows.get(id);
      if (!row?.offers?.some((offer) => offer.childSessionId === child)) continue;
      this.rows.set(id, {
        ...row,
        version: row.version + 1,
        offers: row.offers.map((offer) => this.liveOffer(offer)),
      });
    }
    this.watchOfferChildren();
    this.emitInFrame("offer child");
  }
  /// This Mac's acpmux health row for harness `id` (`_acpmux/harness/health`, cx-ny85), or
  /// undefined: `refresh` checks again; `rescan` has acpmux look for harnesses first (after an
  /// install from the Harnesses page).
  async harnessHealth(id: string, options: { refresh?: boolean; rescan?: boolean } = {}): Promise<unknown> {
    const rows = await this.harnessHealthRows(options);
    return rows.find((row) => (row as { id?: unknown } | null)?.id === id);
  }
  /// Every harness's health row from this Mac's acpmux (`_acpmux/harness/health`): its last check
  /// unless `refresh`; the model picker's rail reads which ones are signed out (cx-ae9eb).
  async harnessHealthRows(options: { refresh?: boolean; rescan?: boolean } = {}): Promise<unknown[]> {
    const reply = await this.request("_acpmux/harness/health", {
      ...(options.refresh ? { refresh: true } : {}),
      ...(options.rescan ? { rescan: true } : {}),
    });
    return Array.isArray(reply?.harnesses) ? reply.harnesses : [];
  }
  /// The routes acpmux has (`_acpmux/route/list`) with `sessionId`'s active one: the composer's
  /// Account menu. Each route says whether it `serves` the session's harness family.
  async routes(sessionId: string): Promise<unknown> {
    return this.request("_acpmux/route/list", { sessionId });
  }
  /// Binds chat `sessionId` to route `routeId` (null: back to its default) through
  /// `_acpmux/chat/route.set`. acpmux restarts the harness on it and resumes the same agent
  /// session, now when idle, else once the running turn ends.
  async setChatRoute(sessionId: string, routeId: string | null): Promise<unknown> {
    return this.request("_acpmux/chat/route.set", { sessionId, routeId, when: "after-turn" });
  }
  /// Changes a waiting prompt (`_acpmux/queue_edit`): `update` its text, `move` it to `index`
  /// (0 runs next) or `send_now`. `ok` is false when it no longer waits.
  async editQueued(promptId: string, edit: QueueEdit): Promise<{ ok: boolean }> {
    if (!this.selectedSessionId) return { ok: false };
    return this.request("_acpmux/queue_edit", {
      sessionId: this.selectedSessionId,
      promptId,
      ...edit,
    });
  }
  /// Answers a permission: `optionId` picks an option (absent cancels the request), and
  /// `answers` carries a question's harness-shaped answers (question/model.ts `reply`). An option
  /// pick first takes a gesture ticket for this prompt and option (`transport.gesture`): the host
  /// signs an allow for another machine's agent daemon only for that exact pick (cx-0q7o).
  async permission(permissionId: string, optionId?: string, answers?: Record<string, unknown>): Promise<void> {
    const sessionId = this.selectedSessionId;
    if (!sessionId) return;
    const ticket =
      optionId === undefined || answers !== undefined
        ? undefined
        : await postNative<{ ticket?: string }>("transport.gesture", {
            intent: {
              method: "_acpmux/permission_respond",
              params: { sessionId, permissionId, optionId },
            },
          }).then(
            (reply) => reply?.ticket,
            () => undefined,
          );
    await typedRequest((method, params) => this.request(method, params), "_acpmux/permission_respond", {
      sessionId,
      permissionId,
      ...(optionId === undefined ? {} : { optionId }),
      ...(answers === undefined ? {} : { answers }),
      ...gestureMeta(ticket),
    });
  }
  /// Answers a secret card: `value` provides it (acpmux keeps it in memory and gives the agent a
  /// one-use ref), none declines. The wire log never holds the value (wire.ts).
  async secret(secretId: string, value?: string): Promise<void> {
    const sessionId = this.selectedSessionId;
    if (!sessionId) return;
    try {
      await this.request("_acpmux/secret_submit", {
        sessionId,
        secretId,
        ...(value ? { value } : {}),
      });
    } catch (error) {
      // A card acpmux no longer has never gets its answer: close it. Any other refusal keeps it.
      const message = error instanceof Error ? error.message : "";
      if (!SECRET_GONE.some((gone) => message.includes(gone))) throw error;
      if (this.pendingSecret?.secretId === secretId) this.pendingSecret = undefined;
      this.emit();
    }
  }
  async permissionGroup(groupId: string, revision: number, decision: PermissionDecision): Promise<void> {
    await this.permissions.respond(groupId, revision, decision);
  }
  async select(sessionId: string): Promise<string | undefined> {
    const previousSessionId = this.selectedSessionId;
    const generation = ++this.selectionGeneration;
    // What the pane shows (the chat before, a new chat's hero) stays drawn until this chat's attach page is in.
    const hold = this.holdSnapshots(SWITCH_HOLD_MS);
    this.selectedSessionId = sessionId;
    this.missingSession = undefined;
    this.markSeen(sessionId);
    this.resetSessionState();
    try {
      if (previousSessionId) await this.request("_acpmux/detach", { sessionId: previousSessionId });
      await this.attach(sessionId, generation);
    } finally {
      this.releaseSnapshots(hold);
    }
    return generation === this.selectionGeneration && this.selectedSessionId === sessionId ? sessionId : undefined;
  }

  /// While a chat is opened (a connect or reconnect, a switch, a new chat's first send, a fallback
  /// after the chat went away), the client draws no snapshot until the chat's attach page is in:
  /// the pane keeps what it showed, then draws the chat whole, never the emptied state in between
  /// (the New chat screen or a blank transcript, no composer, no access chip, no permission state
  /// for the attach's round trip; Leo 2026-10-19, test/agent-pane-switch-frames.test.ts). A slow
  /// open draws what it has after its limit anyway. One hold at a time: a newer one replaces it.
  private snapshotHold?: { key: number; timer: ReturnType<typeof setTimeout>; connection?: string };
  private holdKeys = 0;

  private holdSnapshots(limitMs: number): number {
    const key = ++this.holdKeys;
    if (this.snapshotHold) clearTimeout(this.snapshotHold.timer);
    const connection = this.snapshotHold?.connection;
    this.snapshotHold = { key, connection, timer: setTimeout(() => this.releaseSnapshots(key), limitMs) };
    return key;
  }

  /// Ends hold `key` and draws the snapshot it held back, if any.
  private releaseSnapshots(key: number): void {
    if (this.snapshotHold?.key !== key) return;
    clearTimeout(this.snapshotHold.timer);
    const connection = this.snapshotHold.connection;
    this.snapshotHold = undefined;
    if (connection !== undefined) this.emit(connection);
  }
  /// The one route of a trust refusal (cx-nn3e): acpmux refuses `session/new`, `session/prompt`
  /// and a prewarm in a folder without a Trust answer (`trust_gate.rs`). Every caller hands its
  /// refusal here with the step to re-run after Trust; the pane shows the folder's one question.
  /// A refusal that comes before the pane set its route (an adopt while connecting) waits for it.
  get onTrustRefused(): TrustRoute | undefined {
    return this.trustRoute;
  }
  set onTrustRefused(route: TrustRoute | undefined) {
    this.trustRoute = route;
    const waiting = this.waitingTrust;
    this.waitingTrust = undefined;
    if (route && waiting) route(waiting.refusal, waiting.again);
  }
  private trustRoute?: TrustRoute;
  private waitingTrust?: { refusal: TrustRefusal; again?: () => void };
  /// True when `error` is a trust refusal, which then went to the route.
  routeTrustRefusal(error: unknown, again?: () => void): boolean {
    const refusal = trustRefusal(error);
    if (!refusal) return false;
    if (this.trustRoute) this.trustRoute(refusal, again);
    else this.waitingTrust = { refusal, again };
    return true;
  }
  /// `session/new` for every caller: a trust refusal goes to the one route, then rejects as before.
  private async newSession(params: Record<string, unknown>, again?: () => void): Promise<any> {
    try {
      return await this.request("session/new", params);
    } catch (error) {
      this.routeTrustRefusal(error, again);
      throw error;
    }
  }
  /// A new session, in `cwd` when given; otherwise in the inherited cwd, then where acpmux defaults.
  /// `noProject` starts it in no project: the host's agent-home folder, never the inherited cwd.
  create(harness?: string, cwd?: string, peer?: string, noProject = false): Promise<string | undefined> {
    const started = (async () => {
      const sessionId = await this.startSession(
        harness,
        cwd,
        peer,
        () => void this.create(harness, cwd, peer, noProject).catch(() => undefined),
        noProject,
      );
      return sessionId ? this.select(sessionId) : undefined;
    })();
    const tracked = started.finally(() => {
      if (this.creating === tracked) this.creating = undefined;
    });
    // A rejection is the caller's to handle; the tracked copy only orders sends behind it.
    tracked.catch(() => undefined);
    this.creating = tracked;
    return started;
  }
  /// `session/new` without showing it: a harness switch starts the session behind the pane's
  /// new chat and shows it once it is ready (harnessSwitch.ts).
  /// `again` re-runs the caller's step after a Trust answer (the trust route).
  async startSession(
    harness?: string,
    cwd?: string,
    peer?: string,
    again?: () => void,
    noProject = false,
  ): Promise<string | undefined> {
    const result = await this.newSession(
      newSessionParams(cwd ? { cwd, peer } : noProject ? { peer } : { ...this.host, peer }, harness, noProject),
      again,
    );
    // The inherited cwd is the first default chat's; later ones start where acpmux defaults.
    if (result?.sessionId && !cwd) this.host = { ...this.host, cwd: undefined };
    return result?.sessionId ? String(result.sessionId) : undefined;
  }
  /// The shown session, for a harness switch: whether it has nothing in it yet (a pick back to
  /// its harness reuses it), its harness, and its folder when it runs on this machine (the new
  /// chat starts there; a cloud or peer session's folder is not one acpmux can start in here).
  shownSession(): { sessionId: string; harness?: string; model?: string; empty: boolean; cwd?: string } | undefined {
    const sessionId = this.selectedSessionId;
    if (!sessionId) return undefined;
    const summary = this.summary?.sessionId === sessionId ? this.summary : undefined;
    const turns = Number(summary?.turnCount ?? 0);
    const local = hostKind(summary?.hostKind) !== "cloud" && !text(summary?.host);
    return {
      sessionId,
      harness: typeof summary?.harness === "string" ? summary.harness : undefined,
      ...(typeof summary?.model === "string" && summary.model ? { model: summary.model } : {}),
      empty: this.rows.size === 0 && this.queue.length === 0 && turns === 0 && !this.turnOpen,
      ...(local && typeof summary?.cwd === "string" && summary.cwd ? { cwd: summary.cwd } : {}),
    };
  }
  /// A turn is running in the shown session.
  turnRunning(): boolean {
    return this.turnOpen || this.summary?.status === "running";
  }
  /// Stops showing the selected session: a harness switch draws its new chat meanwhile. The
  /// session keeps running in acpmux; only this client's attach ends.
  leave(): void {
    const previous = this.selectedSessionId;
    if (!previous) return;
    this.selectedSessionId = undefined;
    this.selectionGeneration += 1;
    this.resetSessionState();
    this.emit();
    void this.request("_acpmux/detach", { sessionId: previous }).catch(() => undefined);
  }
  /// Ends a session a superseded harness switch started and nobody used.
  discard(sessionId: string): void {
    if (sessionId === this.selectedSessionId) return;
    void this.request("_acpmux/kill", { sessionId, purge: true }).catch(() => undefined);
  }
  /// acpmux serves `_acpmux/prewarm` to this connection: it lists the method and calls the
  /// connection local. A remote-origin connection is never asked (acpmux refuses it).
  get startsOnSend(): boolean {
    // A chat on another machine (the host's remote wire): its `session/new` starts the chat there,
    // so nothing creates one before the first send (cx-k21v).
    return this.origin === "remote";
  }
  get prewarmSupported(): boolean {
    return this.localOrigin && this.extensions.includes(PREWARM_METHOD);
  }
  /// Hints acpmux's session pool that `harness` is likely next, in `cwd` when known. Never
  /// awaited; a refusal (the pool is off, a failed start) is ignored.
  prewarm(harness: string, cwd?: string): void {
    if (!this.prewarmSupported) return;
    // A prewarm in a folder without a Trust answer asks the question early (nothing to re-run).
    void this.request(PREWARM_METHOD, cwd ? { harness, cwd } : { harness }).catch((error: unknown) => {
      this.routeTrustRefusal(error);
    });
  }
  /// The permission mode acpmux would start a new chat on `harness` in `cwd` in (cx-wx93i),
  /// as acpmux decides it; undefined when it would set none, does not know, or predates the method.
  async startMode(harness: string, cwd?: string): Promise<StartMode | undefined> {
    try {
      const answer = (await this.request("_acpmux/start_mode", cwd ? { harness, cwd } : { harness })) as {
        modeId?: unknown;
        name?: unknown;
      } | null;
      if (typeof answer?.modeId !== "string" || !answer.modeId) return undefined;
      return {
        modeId: answer.modeId,
        ...(typeof answer.name === "string" && answer.name ? { name: answer.name } : {}),
      };
    } catch {
      return undefined;
    }
  }
  /// Resumes `adopt` in this pane now (a chat whose folder was missing, after Choose Folder): the
  /// same path as an adopt on connect, so a trust refusal asks the question (the trust route).
  async resume(adopt: AcpmuxAdopt): Promise<string | undefined> {
    await this.adoptChat(adopt);
    return this.adopted;
  }
  /** The session an adopt on connect resumed, for the host to keep as the tab's session. */
  adopted?: string;
  /// Resumes the outside chat the host named, once. A session that didn't adopt it (an acpmux
  /// without adopt starts a fresh one) is removed, and the pane says so instead of posing as it.
  /// A socket that drops meanwhile fails the connect, so the host reconnects and adopts again
  /// (acpmux maps one chat to one session).
  private async adoptChat(adopt: AcpmuxAdopt): Promise<void> {
    this.host = { ...this.host, adopt: undefined };
    let result: any;
    try {
      // After Trust the same chat is adopted again.
      result = await this.newSession(
        newSessionParams({ adopt }),
        () => void this.adoptChat(adopt).catch(() => undefined),
      );
    } catch (error) {
      if (this.socket?.readyState !== WebSocket.OPEN) throw error;
      // The trust route asks about the folder; this is no failure to resume.
      if (trustRefusal(error)) return;
      if (error instanceof AcpmuxRpcError && error.reason === "adopt.live" && !adopt.ifLive) {
        this.liveAdopt = { adopt, ...liveDetails((error as { details?: unknown }).details) };
        this.emit();
        return;
      }
      this.adoptFailed(error instanceof Error && error.message ? error.message : undefined);
      return;
    }
    const sessionId = result?.sessionId ? String(result.sessionId) : undefined;
    // A fork is a new conversation: its harness session is its own, not the adopted one.
    if (sessionId && (adopt.ifLive === "fork" || adoptedBy(result, adopt))) {
      this.adopted = sessionId;
      await this.select(sessionId);
      return;
    }
    if (sessionId) await this.request("_acpmux/kill", { sessionId, purge: true }).catch(() => undefined);
    this.adoptFailed(translate("notice.resumeUnsupported"));
  }
  /// Adopts the chat acpmux refused as live elsewhere anyway: `open` resumes it as it is (two
  /// processes then write one conversation), `fork` starts a new chat from it. Once; a second
  /// click while it adopts does nothing.
  async adoptLive(choice: "fork" | "open"): Promise<void> {
    const live = this.liveAdopt;
    if (!live || (choice === "fork" && !live.canFork)) return;
    this.liveAdopt = undefined;
    this.emit();
    await this.adoptChat({ ...live.adopt, ifLive: choice });
  }
  /// A line in the shown transcript (a pick the agent refused).
  notice(text: string): void {
    const at = Date.now();
    const id = noticeId("notice");
    this.rows.set(id, { id, version: 1, at, kind: "notice", text });
    this.emit();
  }
  private adoptFailed(reason?: string): void {
    const at = Date.now();
    const id = noticeId("notice-adopt");
    this.rows.set(id, {
      id,
      version: 1,
      at,
      kind: "notice",
      text: reason ? translate("notice.resumeFailedReason", { reason }) : translate("notice.resumeFailed"),
    });
    this.emit();
  }
  /// Forks the open session (or `from`, the chat it was forked from) through the turn whose summary
  /// is `throughSeq`, and opens the fork. One fork at a time; a second click while acpmux forks does
  /// nothing. A failure says so in the transcript; a reader who opened another session meanwhile
  /// stays there. `stay` keeps this chat open and only answers the fork, for its own tab.
  async fork(throughSeq: number, from?: string, stay = false): Promise<string | undefined> {
    if (!this.canFork || !this.selectedSessionId || this.forking) return undefined;
    this.forking = true;
    const generation = this.selectionGeneration;
    try {
      const result = await this.request(FORK_OP, {
        sessionId: from ?? this.selectedSessionId,
        throughSeq,
      });
      if (!result?.sessionId || generation !== this.selectionGeneration) return undefined;
      if (stay) return String(result.sessionId);
      return await this.select(String(result.sessionId));
    } catch (error) {
      if (generation === this.selectionGeneration) {
        const at = Date.now();
        const reason = error instanceof Error && error.message ? error.message : undefined;
        const id = noticeId("notice-fork");
        this.rows.set(id, {
          id,
          version: 1,
          at,
          kind: "notice",
          text: reason ? translate("notice.forkFailedReason", { reason }) : translate("notice.forkFailed"),
        });
        this.emit("fork failed");
      }
      return undefined;
    } finally {
      this.forking = false;
    }
  }
  /// Forks the open session through `throughSeq` and stays on it: New side chat's copy, which the
  /// host opens beside this chat. One fork at a time, as `fork`.
  async forkAside(throughSeq: number): Promise<string | undefined> {
    if (!this.canFork || !this.selectedSessionId || this.forking) return undefined;
    this.forking = true;
    try {
      const result = await this.request(FORK_OP, { sessionId: this.selectedSessionId, throughSeq });
      return result?.sessionId ? String(result.sessionId) : undefined;
    } finally {
      this.forking = false;
    }
  }
  /// Asks a side question about the open session (`/btw`). acpmux answers it in a throwaway copy
  /// of the chat (`_acpmux/ask`), so the chat never holds it. Resolves to the answer's text.
  async ask(question: string): Promise<string> {
    if (!this.selectedSessionId) return "";
    const result = await this.request("_acpmux/ask", {
      sessionId: this.selectedSessionId,
      text: question,
    });
    return typeof result?.text === "string" ? result.text : "";
  }
  async setModel(modelId: string): Promise<void> {
    if (this.selectedSessionId) await this.request("session/set_model", { sessionId: this.selectedSessionId, modelId });
  }
  /// `ticket`: a gesture ticket a held pick took (pane-native transport, `transport.gesture`); it
  /// rides as `_meta.cmuxGesture`, and the host strips it before acpmux.
  async setMode(modeId: string, ticket?: string): Promise<void> {
    if (this.selectedSessionId)
      await this.request("session/set_mode", {
        sessionId: this.selectedSessionId,
        modeId,
        ...gestureMeta(ticket),
      });
  }
  /// The session's summary reads the agent's answer, its whole option list: acpmux sends no
  /// session change for it, so without this the chip and menu keep the old level.
  async setConfig(configId: string, value: string, ticket?: string): Promise<void> {
    const sessionId = this.selectedSessionId;
    if (!sessionId) return;
    const result = await this.request("session/set_config_option", {
      sessionId,
      configId,
      value,
      ...gestureMeta(ticket),
    });
    if (sessionId !== this.selectedSessionId || !Array.isArray(result?.configOptions)) return;
    this.summary = { ...this.summary, configOptions: result.configOptions };
    this.emit();
  }
  /** The harness and model catalog. Server state the pane caches with TanStack Query (catalog.ts), so connect does not wait on it.
   *  With `cwd` (the chat's folder) it also holds that folder's harness profiles (`folder` entries,
   *  docs/add-your-harness.md). A refused `cwd` (an older acpmux, a folder outside the roots)
   *  falls back to the list without it, so the catalog never empties over a folder. */
  async harnesses(cwd?: string): Promise<AcpmuxSnapshot["catalog"]> {
    // The harness list carries no models; acpmux serves the probed ones apart (modelCatalog.ts).
    const [names, probed] = await Promise.all([
      cwd
        ? this.request("_acpmux/harnesses", { cwd }).catch(() => this.request("_acpmux/harnesses", {}))
        : this.request("_acpmux/harnesses", {}),
      this.request("_acpmux/models", {}).catch(() => undefined),
    ]);
    const catalog = mergeModelCatalog(names, probed);
    const profiles = normalizeFolderProfiles(names);
    if (profiles.length === 0) return catalog;
    // A probed folder profile keeps its models; it is listed once, as the folder's.
    const ids = new Set(profiles.map((profile) => profile.id));
    const models = new Map(catalog.map((entry) => [entry.id, entry.models]));
    return [
      ...catalog.filter((entry) => !ids.has(entry.id)),
      ...profiles.map((profile) => ({
        ...profile,
        models: models.get(profile.id) ?? profile.models,
      })),
    ];
  }
  /// Probes every agent's live model list again (`_acpmux/models {refresh: true}`): acpmux forgets
  /// the lists it has and asks each harness before it answers (the picker's Refresh models).
  refreshModels(): Promise<unknown> {
    return this.request("_acpmux/models", { refresh: true });
  }
  /// Enables a folder profile (`_acpmux/harness_enable {folder, id}`). Call it straight from the
  /// click or key handler, with no await before it: the host takes the gesture, shows its own
  /// confirmation and adds the file's hash itself (the pane never sends one). A Cancel there
  /// rejects with code `transport.harness_not_confirmed`; when acpmux refused to give the prompt
  /// (no Trust answer, an invalid file), that rejection carries its reason as `detail`; when
  /// acpmux gave no prompt (down, too slow), `reason` is `harness.prompt_unavailable`.
  harnessEnable(folder: string, id: string): Promise<unknown> {
    return this.request("_acpmux/harness_enable", { folder, id });
  }
  /// Pages older transcript events in without reattaching, so the live summary,
  /// queue and permission stay as they are. A page that lands after the
  /// selection changed belongs to another session and is dropped.
  loadOlder(): Promise<void> {
    if (Date.now() < this.olderRetryAt) return Promise.resolve();
    if (this.loadingOlder) return this.loadingOlder;
    const loading = this.fetchOlder()
      .catch((error: unknown) => {
        this.olderRetryAt = Date.now() + 2_000;
        throw error;
      })
      .finally(() => {
        if (this.loadingOlder === loading) this.loadingOlder = undefined;
      });
    this.loadingOlder = loading;
    return loading;
  }
  private async fetchOlder(): Promise<void> {
    if (!this.selectedSessionId || !this.firstSeq || this.firstSeq <= 1 || this.historyExhausted) return;
    const sessionId = this.selectedSessionId;
    const generation = this.selectionGeneration;
    const result = await this.request("_acpmux/events", {
      sessionId,
      beforeSeq: this.firstSeq,
      limit: 400,
      maxBytes: OLDER_PAGE_BYTES,
      kinds: ["transcript"],
    });
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return;
    let older: EventRecord[] = result?.events ?? [];
    const more = result?.hasMore === true;
    // A page whose first records finish the turn before it leaves them to the next page, so pages
    // hold whole turns and fold on their own.
    const start = more ? older.findIndex(startsTurn) : 0;
    if (start > 0) older = older.slice(start);
    if (start >= 0 && (this.events.length === 0 || startsTurn(this.events[0]!))) {
      this.events = mergeEventRecords(older, this.events);
      this.foldOlder(older);
    } else {
      // The open page began mid-turn (or this page holds no turn start): fold everything once.
      this.events = mergeEventRecords(older, this.events);
      this.rebuildKeepingLiveState();
    }
    this.historyExhausted = !more || older.length === 0 || (this.firstSeq ?? 1) <= 1;
    this.emit("history");
  }

  /// Folds whole turns older than every held event into rows above them, without folding the held
  /// events again: the cost of a page stays the page's however much history is loaded. The fold
  /// starts from a clean turn and leaves the live state (an open turn, its stream and typing row,
  /// asks, commands, usage, prompts in flight) as the held events made it.
  private foldOlder(older: EventRecord[]): void {
    const live = {
      turnOpen: this.turnOpen,
      streamingAssistant: this.streamingAssistant,
      streamingAssistantMessageId: this.streamingAssistantMessageId,
      streamingActivity: this.streamingActivity,
      planRow: this.planRow,
      messageRows: this.messageRows,
      toolRows: this.toolRows,
      planCalls: this.planCalls,
      subagents: this.subagents,
      summary: this.summary,
      queue: this.queue,
      pendingPermission: this.pendingPermission,
      pendingSecret: this.pendingSecret,
      groupedPermissions: this.groupedPermissions,
      openQuestions: this.openQuestions,
      heldEdits: this.heldEdits,
      usage: this.usage,
      forkedAtSeq: this.forkedAtSeq,
      optimisticPromptRows: this.optimisticPromptRows,
      optimisticPromptTexts: this.optimisticPromptTexts,
      promptAccepts: this.promptAccepts,
    };
    const held = new Map(this.rows);
    this.turnOpen = false;
    this.streamingAssistant = undefined;
    this.streamingAssistantMessageId = undefined;
    this.streamingActivity = undefined;
    this.planRow = undefined;
    this.messageRows = new Map();
    this.toolRows = new Map();
    this.planCalls = new Set();
    this.subagents = new SubagentFold();
    this.groupedPermissions = new Map();
    this.openQuestions = new Set();
    this.heldEdits = new Set();
    // An older prompt never settles one still sending, however alike their text.
    this.optimisticPromptRows = new Map();
    this.optimisticPromptTexts = new Map();
    this.promptAccepts = new Map();
    this.foldingBelow = this.firstSeq ?? Infinity;
    try {
      for (const event of [...older].sort((a, b) => a.seq - b.seq)) {
        this.firstSeq = Math.min(this.firstSeq ?? event.seq, event.seq);
        this.reduce(event);
      }
    } finally {
      this.foldingBelow = undefined;
    }
    // A fork older than every held event is only in this page.
    const forkedAtSeq = live.forkedAtSeq ?? this.forkedAtSeq;
    Object.assign(this, live, { forkedAtSeq });
    // Older turns end on their own result; a row of the live turn it closed (its typing row) stays.
    for (const [id, row] of held) if (!this.rows.has(id)) this.rows.set(id, row);
  }
  /// The socket's own onclose ignores a socket close() already let go of, so settle requests here.
  close(): void {
    this.closed = true;
    this.sessionPages.stop();
    clearTimeout(this.sessionReread);
    this.sessionReread = undefined;
    clearTimeout(this.stopTimer);
    this.stopTimer = undefined;
    if (typeof document !== "undefined") document.removeEventListener("visibilitychange", this.showChanged);
    if (this.reconnectTimer !== undefined) window.clearTimeout(this.reconnectTimer);
    this.reconnectTimer = undefined;
    this.permissions.disconnected();
    this.socket?.close();
    this.socket = undefined;
    this.rejectPending();
  }
  private rejectPending(): void {
    for (const request of this.pending.values()) {
      if (request.timer) clearTimeout(request.timer);
      request.reject(
        Object.assign(new Error(translate("error.interrupted")), {
          code: "native.timed_out",
          origin: "native",
        }),
      );
    }
    this.pending.clear();
  }
}

/// The params field that carries a pick's gesture ticket, or nothing without one.
const gestureMeta = (ticket?: string) => (ticket ? { _meta: { cmuxGesture: ticket } } : {});

/// Why acpmux says a harness will not start: its launcher check, else its failed model probe.
/// A prompt acpmux refused because the session's folder has no Trust answer (`trust_gate.rs`).
export function isTrustRefusal(error: unknown): boolean {
  // The reasons acpmux's trust gate writes (trust_gate.rs; checked against trust_gate.json).
  const reason = (error as { reason?: unknown } | null)?.reason;
  return reason === "trust.pending" || reason === "trust.untrusted";
}

/// What a trust refusal names: its reason and the folder acpmux asks about.
export type TrustRefusal = { reason: "trust.pending" | "trust.untrusted"; cwd?: string };
/// The pane's handler of every trust refusal (`AcpmuxDirectClient.onTrustRefused`).
export type TrustRoute = (refusal: TrustRefusal, again?: () => void) => void;

export function trustRefusal(error: unknown): TrustRefusal | undefined {
  if (!isTrustRefusal(error)) return undefined;
  const fields = error as { reason: TrustRefusal["reason"]; cwd?: unknown };
  return {
    reason: fields.reason,
    ...(typeof fields.cwd === "string" && fields.cwd ? { cwd: fields.cwd } : {}),
  };
}

export function harnessRefusal(entry: { unavailable?: unknown; probeError?: unknown } | undefined): string | undefined {
  for (const reason of [entry?.unavailable, entry?.probeError]) if (typeof reason === "string" && reason) return reason;
  return undefined;
}

const FOLDER_STATES = ["enabled", "needs-enable", "needs-trust", "error"] as const;

/// The folder profiles of a `_acpmux/harnesses {cwd}` reply (`folderProfiles`) as catalog entries.
/// An entry without an id, a folder or a known state is dropped.
export function normalizeFolderProfiles(value: any): AcpmuxSnapshot["catalog"] {
  const profiles: any[] = Array.isArray(value?.folderProfiles) ? value.folderProfiles : [];
  return profiles.flatMap((profile) => {
    const id = typeof profile?.id === "string" ? profile.id : "";
    const folder = typeof profile?.folder === "string" ? profile.folder : "";
    const state = FOLDER_STATES.find((candidate) => candidate === profile?.state);
    if (!id || !folder || !state) return [];
    const first = Array.isArray(profile.diagnostics) ? profile.diagnostics[0] : undefined;
    const diagnostic =
      typeof first === "string" ? first : typeof first?.message === "string" ? first.message : undefined;
    return [
      {
        id,
        name: typeof profile.displayName === "string" && profile.displayName ? profile.displayName : id,
        models: Array.isArray(profile.models) ? profile.models.map((model: unknown) => catalogModel(model)) : [],
        ...(typeof profile.family === "string" && profile.family ? { family: profile.family } : {}),
        ...(typeof profile.icon === "string" && profile.icon ? { icon: profile.icon } : {}),
        folder: {
          folder,
          ...(typeof profile.path === "string" ? { path: profile.path } : {}),
          state,
          ...(diagnostic ? { diagnostic } : {}),
        },
      },
    ];
  });
}

/// A `session/new` acpmux refused because the chat's folder profile is not enabled yet
/// (`harness.needs_enable`) or its folder has no Trust answer (`harness.needs_trust`).
export type HarnessBlock = {
  reason: "needs-enable" | "needs-trust";
  harness: string;
  folder: string;
};

export function harnessBlock(error: unknown): HarnessBlock | undefined {
  const data = (error as { data?: unknown } | null)?.data as
    | { reason?: unknown; harness?: unknown; folder?: unknown }
    | undefined;
  const reason =
    data?.reason === "harness.needs_enable"
      ? "needs-enable"
      : data?.reason === "harness.needs_trust"
        ? "needs-trust"
        : undefined;
  if (!reason || typeof data?.harness !== "string" || typeof data.folder !== "string") return undefined;
  return { reason, harness: data.harness, folder: data.folder };
}

/// A `compaction` update's state and sizes; undefined for a state acpmux does not send.
function compactionOf(update: any): AcpmuxCompaction | undefined {
  const state = update?.state;
  if (state !== "running" && state !== "completed" && state !== "failed") return undefined;
  const count = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : undefined);
  return {
    state,
    ...(typeof update.reason === "string" && update.reason ? { reason: update.reason } : {}),
    ...(count(update.preTokens) !== undefined ? { preTokens: count(update.preTokens) } : {}),
    ...(count(update.postTokens) !== undefined ? { postTokens: count(update.postTokens) } : {}),
  };
}

/// A `background_task_update`'s shell and how it ended; undefined when it names neither.
/// A `session_offer` record's offer, or undefined when it lacks an id, title, prompt or folder.
function sessionOffer(msg: any): AcpmuxSessionOffer | undefined {
  const field = (key: string) => (typeof msg?.[key] === "string" ? (msg[key] as string) : "");
  const [offerId, title, prompt, cwd] = ["offerId", "title", "prompt", "cwd"].map(field);
  if (!offerId || !title || !prompt || !cwd) return undefined;
  return {
    offerId,
    title,
    prompt,
    cwd,
    worktree: msg.worktree === true,
    ...(field("harness") ? { harness: field("harness") } : {}),
    ...(field("model") ? { model: field("model") } : {}),
    ...(field("groupId") ? { groupId: field("groupId") } : {}),
  };
}

/// The started offer a `user_message` brings the result of (`_meta.provenance`, kind
/// `offer_result`), or undefined for any other prompt.
function offerResult(msg: any): AcpmuxOfferResult | undefined {
  const provenance = msg?._meta?.provenance;
  if (provenance?.kind !== "offer_result") return undefined;
  const [offerId, childSessionId, title] = [provenance.offerId, provenance.childSessionId, provenance.title];
  if (typeof offerId !== "string" || typeof childSessionId !== "string" || typeof title !== "string" || !title)
    return undefined;
  return { offerId, childSessionId, title };
}

function backgroundTask(update: any): AcpmuxBackgroundTask | undefined {
  const state = update.state;
  if (typeof update.toolCallId !== "string" || !["completed", "failed", "stopped"].includes(state)) return undefined;
  return {
    toolCallId: update.toolCallId,
    command: typeof update.command === "string" ? update.command : "",
    state,
    ...(typeof update.reason === "string" && update.reason ? { reason: update.reason } : {}),
  };
}

/// An ACP `plan` update's entries as a todo list; an entry without text is left out.
function planEntries(entries: unknown): AcpmuxPlanEntry[] {
  if (!Array.isArray(entries)) return [];
  return entries.flatMap((entry) => {
    const content = typeof entry?.content === "string" ? entry.content.trim() : "";
    if (!content) return [];
    const status = entry.status === "completed" || entry.status === "in_progress" ? entry.status : "pending";
    return [{ content, status }];
  });
}

/// One `_acpmux/models` entry: id and name, plus the metadata a declared profile model carries.
export function catalogModel(model: any): AcpmuxSnapshot["catalog"][number]["models"][number] {
  const entry: AcpmuxSnapshot["catalog"][number]["models"][number] = {
    id: String(model?.id ?? model?.modelId),
    name: typeof model?.name === "string" ? model.name : undefined,
  };
  if (typeof model?.unavailable === "string") entry.unavailable = model.unavailable;
  for (const key of ["shortName", "family", "defaultEffort"] as const)
    if (typeof model?.[key] === "string" && model[key]) entry[key] = model[key];
  if (Array.isArray(model?.efforts))
    entry.efforts = model.efforts.filter((value: unknown) => typeof value === "string");
  if (typeof model?.fast === "boolean") entry.fast = model.fast;
  if (Number.isInteger(model?.contextWindow) && model.contextWindow > 0) entry.contextWindow = model.contextWindow;
  return entry;
}

/// A harness map's entries in acpmux's order: its default (`defaultHarness`) first, then by id. The
/// native relay re-encodes the reply, so the map's own key order means nothing (a first launch
/// asked the model router instead of Claude Code).
function harnessEntries(harnesses: Record<string, unknown>, preferred: unknown): any[] {
  const ids = Object.keys(harnesses).sort((a, b) =>
    a === preferred ? -1 : b === preferred ? 1 : a < b ? -1 : a > b ? 1 : 0,
  );
  return ids.map((id) => ({ id, ...(harnesses[id] as any) }));
}

/// `_acpmux/harnesses` `start` ({model?, effort?, modelSource?, effortSource?}), with only its
/// known fields.
function harnessStart(value: unknown): AcpmuxSnapshot["catalog"][number]["start"] {
  if (!value || typeof value !== "object") return undefined;
  const { model, effort, modelSource, effortSource } = value as Record<string, unknown>;
  const source = (raw: unknown) =>
    raw === "saved" || raw === "profile" || raw === "catalog" ? (raw as StartSource) : undefined;
  const start = {
    ...(typeof model === "string" && model ? { model } : {}),
    ...(typeof effort === "string" && effort ? { effort } : {}),
    ...(source(modelSource) ? { modelSource: source(modelSource) } : {}),
    ...(source(effortSource) ? { effortSource: source(effortSource) } : {}),
  };
  return start.model || start.effort ? start : undefined;
}

export function normalizeCatalog(value: any): AcpmuxSnapshot["catalog"] {
  const harnesses = value?.harnesses ?? value?.items ?? value ?? [];
  const entries: any[] = Array.isArray(harnesses) ? harnesses : harnessEntries(harnesses, value?.defaultHarness);
  return entries.map((harness: any) => ({
    id: String(harness.id ?? harness.name),
    name: agentName(
      String(harness.id ?? harness.name),
      typeof harness.displayName === "string" && harness.displayName
        ? harness.displayName
        : harness.name == null
          ? undefined
          : String(harness.name),
    ),
    models: (harness.models ?? []).map((model: any) => catalogModel(model)),
    ...(typeof harness.family === "string" && harness.family ? { family: harness.family } : {}),
    ...(typeof harness.icon === "string" && harness.icon ? { icon: harness.icon } : {}),
    // A terminal harness (Muse Code) runs in a terminal tab, never as a chat: no picker lists it.
    ...(harness.kind === "terminal" ? { pickable: false } : {}),
    ...(harnessStart(harness.start) ? { start: harnessStart(harness.start) } : {}),
    ...(typeof harness.auth?.login === "string" && harness.auth.login.trim()
      ? { auth: { login: harness.auth.login.trim() } }
      : {}),
    // Why acpmux will not start it, when it says: its launcher check (`unavailable`), else its
    // failed model probe (`probeError`).
    ...(harnessRefusal(harness) ? { unavailable: harnessRefusal(harness) } : {}),
    ...(!harness.unavailable && harnessRefusal(harness) ? { probeFailed: true } : {}),
  }));
}

/// Whether the person can see the page: WebKit reports `hidden` for a web view out of its window,
/// hidden, or in an occluded window.
function pageShown(): boolean {
  return typeof document === "undefined" || document.visibilityState !== "hidden";
}
