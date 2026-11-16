// The store's rows as the view's rows (decision 233): a copy by the field table (FIELDS.md), with no
// logic beyond the kind map (`row.kind`, and `body.notice` for a notice). A page-made field is a pure
// function of one row's own fields, of the turn's group row (home b) or of homes d to g, and is
// read with v1's own readers so both draw the same. A field the wire does not carry yet is on
// `notYet.ts` and is left out here, never guessed: the view draws v1's empty state for it.
// The started chats' cards (decision 241) are placed by the view over these rows from the chat list
// (App.tsx `withStartedSessions`), as with v1.
import { permissionFromMessage, mergeToolItem, textFromContent } from "../direct";
import { harnessModeName } from "../harnessModes";
import { translate } from "../i18n";
import type { AcpmuxRow, QueuedPrompt } from "../model";
import { answeredBy } from "../multiplayer/participants";
import { DECISION_TEXT, PERMISSION_RECORD, type PermissionDecision } from "../permissions/record";
import type { IncomingContext } from "../conversation/incomingMessage";
import { type UserBody, userPrompt } from "./incoming";
import type { ChatRowEntry, ChatRowsSnapshot } from "./store";
import type { ChatRow } from "./wire";

/// What the page knows of the chat beside its rows: its id (home g), its harness from the list
/// summary (home e, for a mode's name), and the chat list (home g, for a message's addressee).
export type ChatRowsContext = {
  sessionId: string;
  family?: string;
  harness?: string;
  incoming?: IncomingContext;
};

/// The view's rows, queue and paging state from one snapshot.
export type AdaptedChat = {
  rows: AcpmuxRow[];
  queue: QueuedPrompt[];
  canLoadOlder: boolean;
  /// The page of turns' prompts older than the rows held (the snapshot's `earlierPrompts`), for
  /// the thread rail: absent until a page of turns came, and for a daemon with none.
  earlierPrompts?: readonly AcpmuxRow[];
  /// The page of turns' prompts past the last row held (the snapshot's `laterPrompts`): after a
  /// jump to an old prompt let the tail go, the rail still shows every newer prompt (decision 409).
  laterPrompts?: readonly AcpmuxRow[];
  /// Whether the heads and the rows held name every prompt of the chat: the window holds it all,
  /// or the page of turns answered with none before or after its run. Until then the pane sends the
  /// summary's `promptCount`, so the rail starts at its full height.
  promptsHeld: boolean;
};

/// Every prompt is held: the window has no rows before or after it, or the heads' run has none.
function promptsHeld(snapshot: ChatRowsSnapshot): boolean {
  if (!snapshot.hasBefore && !snapshot.hasAfter) return true;
  const heads = snapshot.heads;
  return !!heads && !heads.unsupported && !heads.hasBefore && !heads.hasAfter;
}

const NO_EARLIER: readonly AcpmuxRow[] = Object.freeze([]);

/// A turn's head as the rail's earlier prompt: a `user` row named as its prompt's row is
/// (`row-<rowId>`, the turn's `turn`), so a rail jump to it lands on that row once a page holds it.
/// The prompt's text is the head's start of it (`body.head`).
function earlierPrompt(head: ChatRow): AcpmuxRow | undefined {
  const body = (head.body ?? {}) as { head?: unknown; promptId?: unknown; prompt?: unknown };
  const prompt = typeof body.prompt === "number" ? body.prompt : head.turn;
  if (prompt === undefined) return undefined;
  return {
    id: `row-${prompt}`,
    version: head.rev,
    kind: "user",
    at: head.at * 1000,
    text: typeof body.head === "string" ? body.head : "",
    turnId: String(prompt),
    ...(typeof body.promptId === "string" && body.promptId ? { promptId: body.promptId } : {}),
  };
}

/// The heads' prompts on either side of the rows held, each in order (decision 409): `earlier`
/// those older than the first row held, `later` those past the last. A jump to an old prompt lets
/// the tail go; the newer prompts stay on the rail as `later`.
function railPrompts(snapshot: ChatRowsSnapshot): { earlier: readonly AcpmuxRow[]; later: readonly AcpmuxRow[] } {
  const heads = snapshot.heads?.rows ?? NO_EARLIER_HEADS;
  const first = snapshot.rows[0]?.id ?? Infinity;
  const last = snapshot.rows.at(-1)?.id ?? -Infinity;
  const earlier: AcpmuxRow[] = [];
  const later: AcpmuxRow[] = [];
  for (const head of heads) {
    const row = earlierPrompt(head);
    if (!row) continue;
    const prompt = Number(row.turnId);
    if (prompt < first) earlier.push(row);
    else if (prompt > last) later.push(row);
  }
  return { earlier: earlier.length ? earlier : NO_EARLIER, later: later.length ? later : NO_EARLIER };
}
const NO_EARLIER_HEADS: readonly ChatRow[] = Object.freeze([]);

/// One snapshot's view, adapted whole: the parity test's reading. A page adapts through a
/// `ChatAdapter`, which keeps the rows that did not change.
export function adaptChat(snapshot: ChatRowsSnapshot, context: ChatRowsContext): AdaptedChat {
  return new ChatAdapter(context).adapt(snapshot);
}

/// One chat's snapshots adapted in turn. A row is adapted again only when its row changed (the
/// store keeps an unchanged row's object) or, for a turn's end, its group row did; every other row
/// keeps its view rows' objects, so the view's turn shaping (`turnViewFrom`) keeps the turns before
/// the first changed one. A new context is a new adapter.
export class ChatAdapter {
  #made = new WeakMap<ChatRow, { group: ChatRow | undefined; rows: AcpmuxRow[] }>();
  /// The harness the made rows were adapted under. The page's context reads it from the chat list
  /// as each row is adapted, so a chat chosen before its list row is known learns it later: then
  /// every made row goes, and a decided ask's mode is named by that harness.
  #harness: string | undefined;
  /// `railPrompts`' last answer, by the heads and the first and last rows held it was read from: a
  /// text delta or a row between them makes no new lists.
  #rail:
    | {
        heads: ChatRowsSnapshot["heads"];
        first: number | undefined;
        last: number | undefined;
        earlier: readonly AcpmuxRow[];
        later: readonly AcpmuxRow[];
      }
    | undefined;

  constructor(readonly context: ChatRowsContext) {}

  /// A kept chat keeps no heads (decision 378): its earlier prompts' memo goes with them.
  dropHeads(): void {
    this.#rail = undefined;
  }

  adapt(snapshot: ChatRowsSnapshot): AdaptedChat {
    const harness = this.context.harness;
    if (harness !== this.#harness) {
      this.#harness = harness;
      this.#made = new WeakMap();
    }
    const held = new Map<number, ChatRow>();
    for (const entry of snapshot.rows) if (entry.row) held.set(entry.id, entry.row);
    for (const entry of snapshot.apart) if (entry.row) held.set(entry.id, entry.row);
    const rows: AcpmuxRow[] = [];
    for (const entries of [snapshot.rows, snapshot.apart])
      for (const entry of entries) {
        const row = entry.row;
        if (!row) continue;
        const group = row.kind === "notice" && row.group ? held.get(row.group) : undefined;
        let made = this.#made.get(row);
        if (!made || made.group !== group) {
          made = { group, rows: adaptRow(entry, held, this.context) };
          this.#made.set(row, made);
        }
        rows.push(...made.rows);
      }
    const first = snapshot.rows[0]?.id;
    const last = snapshot.rows.at(-1)?.id;
    let rail = this.#rail;
    if (!rail || rail.heads !== snapshot.heads || rail.first !== first || rail.last !== last)
      this.#rail = rail = { heads: snapshot.heads, first, last, ...railPrompts(snapshot) };
    return {
      ...(rail.earlier.length ? { earlierPrompts: rail.earlier } : {}),
      ...(rail.later.length ? { laterPrompts: rail.later } : {}),
      promptsHeld: promptsHeld(snapshot),
      rows,
      // A cut entry's whole text is a `prompt:<id>` blob once read.
      queue: snapshot.queue.entries.map((entry) => {
        const whole = snapshot.bodies.get(`prompt:${entry.id}`);
        return { id: entry.id, prompt: typeof whole === "string" ? whole : entry.text };
      }),
      canLoadOlder: snapshot.hasBefore,
    };
  }
}

/// One held row as the view's rows: none for a group row (the turn's shape reads it) or a hole.
export function adaptRow(
  entry: ChatRowEntry,
  held: ReadonlyMap<number, ChatRow>,
  context: ChatRowsContext,
): AcpmuxRow[] {
  const row = entry.row;
  if (!row) return [];
  const body = (row.body ?? {}) as Record<string, any>;
  const head = { id: `row-${row.id}`, version: row.rev, at: row.at * 1000 };
  switch (row.kind) {
    case "user":
      return [
        {
          ...head,
          kind: "user",
          ...turnOf(row),
          ...userPrompt(body as UserBody, context.incoming),
          // A steer waits while its row is open (the translate contract keeps it open until read).
          ...(body.steer ? { steer: row.open ? ("waiting" as const) : ("landed" as const) } : {}),
          ...(body.continues ? { continues: true } : {}),
          ...(body.steerPromptId ? { steerPromptId: body.steerPromptId } : {}),
          ...(body.promptId ? { promptId: body.promptId } : {}),
          ...(body.inlineParts?.length ? { inlineParts: body.inlineParts } : {}),
          ...(body.pasted?.length ? { pasted: body.pasted } : {}),
          ...(body.from ? { from: body.from } : {}),
        },
      ];
    case "text":
      return [{ ...head, kind: "assistant", text: String(body.text ?? ""), streaming: row.open }];
    case "thinking":
      return [
        { ...head, kind: "activity", items: [{ kind: "thought", text: String(body.text ?? "") }], streaming: row.open },
      ];
    case "tool": {
      const item = mergeToolItem(undefined, body, String(body.callId ?? ""), textFromContent(body.content));
      return [{ ...head, kind: "activity", toolCount: 1, items: [item], streaming: row.open }];
    }
    case "notice":
      return body.notice === "turn_result"
        ? [{ ...turnSummary(head, body, row.group ? held.get(row.group) : undefined), ...turnOf(row) }]
        : [];
    case "ask":
      return body.ask === "permission" ? permissionRecord(head, body, context) : [];
    default:
      return [];
  }
}

/// The turn-end notice: its own fields, and the turn's time and calls from its group row (home b).
/// A record with no `status` ended its turn: the page reads it `completed`, as v1 does.
function turnSummary(
  head: Pick<AcpmuxRow, "id" | "version" | "at">,
  body: Record<string, any>,
  group?: ChatRow,
): AcpmuxRow {
  const turn = (group?.body ?? {}) as { ms?: number; calls?: number };
  return {
    ...head,
    kind: "turnSummary",
    ...(typeof body.seq === "number" ? { seq: body.seq } : {}),
    ...(typeof turn.ms === "number" ? { durationMs: turn.ms } : {}),
    ...(typeof turn.calls === "number" ? { toolCount: turn.calls } : {}),
    ...(body.tokens ? { tokens: body.tokens } : {}),
    status: typeof body.status === "string" ? body.status : "completed",
    ...(body.continued ? { continued: true } : {}),
    error: typeof body.error === "string" ? body.error : undefined,
    ...(typeof body.errorCode === "string" && body.errorCode ? { errorCode: body.errorCode } : {}),
    ...(body.checkpoint ? { checkpoint: body.checkpoint } : {}),
    ...(body.stopForced ? { stopForced: true as const } : {}),
  };
}

/// A permission ask's receipt (decision 245): the card's permission read from `request` by v1's
/// reader, the decision with the option and the mode named, and the receipt's words from i18n. An
/// approval reads on the call it approved (the tool row's `approved`, on `notYet` until the
/// translator writes it), never as a receipt line, as v1 draws it.
function permissionRecord(
  head: Pick<AcpmuxRow, "id" | "version" | "at">,
  body: Record<string, any>,
  context: ChatRowsContext,
): AcpmuxRow[] {
  const decision = askDecision(body, context);
  const permission = permissionFromMessage(
    { request: body.request, permissionId: body.permissionId, turnId: body.turnId, sessionId: context.sessionId },
    context.sessionId,
  );
  if (!decision || !permission) return [];
  const approved = decision.kind === "allowed" || decision.kind === "allowedAlways" || decision.kind === "fullAccess";
  if (approved && permission.toolCallId) return [];
  const action = permission.title?.trim() || translate("permission.required");
  return [
    {
      ...head,
      kind: PERMISSION_RECORD,
      permission,
      decision,
      ...(answeredBy(body.answeredBy) && { answeredBy: answeredBy(body.answeredBy) }),
      text:
        decision.kind === "fullAccess"
          ? translate(DECISION_TEXT.fullAccess, { action, mode: decision.mode })
          : translate(DECISION_TEXT[decision.kind], {
              action,
              option: decision.kind === "answered" ? decision.option : "",
            }),
    },
  ];
}

/// The row's decision as the view names it: an answered option by its name in the ask's options,
/// a mode by the harness's name for it. Undefined while the ask waits.
export function askDecision(body: Record<string, any>, context: ChatRowsContext): PermissionDecision | undefined {
  const decision = body.decision as { kind?: string; option?: string; mode?: string } | undefined;
  switch (decision?.kind) {
    case "allowed":
    case "allowedAlways":
    case "denied":
    case "cancelled":
      return { kind: decision.kind };
    case "answered": {
      const options = (body.request?.options ?? []) as { optionId?: string; name?: string }[];
      const option = options.find((candidate) => candidate.optionId === decision.option);
      return { kind: "answered", option: option?.name?.trim() || String(decision.option ?? "") };
    }
    case "fullAccess":
      return {
        kind: "fullAccess",
        mode: harnessModeName(context.family, context.harness, String(decision.mode ?? "")),
      };
    default:
      return undefined;
  }
}

/// A turn's identity is its prompt's rowId (`row.turn`), not acpmux's turn id: the view only
/// compares it with other rows' (turns.ts).
function turnOf(row: ChatRow): Pick<AcpmuxRow, "turnId"> {
  return row.turn !== undefined ? { turnId: String(row.turn) } : {};
}
