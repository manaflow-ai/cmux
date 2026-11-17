// A Chief's permission card (Swift `HomeApprovalRowProvider` and `HomeProjection+Approval`): a
// `question` part from the local Chief with one `approval:<digest>` item whose options are allow and
// deny. The card shows the request (its prompt, the tool's input while it waits, then where it
// stands) with Deny and Allow. A click goes to the app (`cmux.home.messages.approval.decide`), which
// answers acpmux's exact pending request on the person's click only and then records the answer on
// the card's message; the page keeps only the card's in-flight state and its note.
import type { HomeConversation, HomeMessage, HomeQuestion } from "../../../home-channels/types";

export const APPROVAL_DECIDE_OP = "cmux.home.messages.approval.decide";

/** What the app answered (Swift `CmuxStrings+Approvals`): the note under the card. */
export type ApprovalNote = "allowed" | "denied" | "expired" | "failed" | "allowedNotRecorded" | "deniedNotRecorded";

export const APPROVAL_NOTE_KEYS: Record<ApprovalNote, string> = {
  allowed: "home.approval.allowed",
  denied: "home.approval.denied",
  expired: "home.approval.stale",
  failed: "home.approval.unavailable",
  allowedNotRecorded: "home.approval.allowedNotRecorded",
  deniedNotRecorded: "home.approval.deniedNotRecorded",
};

/** The card's own state (Swift `HomeApprovalRowProvider.Local`). */
export interface ApprovalLocal {
  busy?: boolean;
  note?: ApprovalNote;
  /** Answered (or gone): the buttons go. */
  ended?: boolean;
}

const HEX64 = /^[0-9a-f]{64}$/;

/** The request digest the card's item names, when the question has the narrow card shape. */
export function approvalDigest(question: HomeQuestion): string | undefined {
  if (question.harness !== "chief" || !question.permission || question.items.length !== 1) return undefined;
  const item = question.items[0]!;
  if (!item.id.startsWith("approval:") || item.multiSelect || item.allowsOther) return undefined;
  const ids = new Set(item.options.map((option) => option.id));
  if (ids.size !== 2 || !ids.has("allow") || !ids.has("deny") || item.options.length !== 2) return undefined;
  const digest = item.id.slice("approval:".length);
  return HEX64.test(digest) ? digest : undefined;
}

/** Only a card from a Chief of a local conversation is a permission card (Swift `HomeMapping.projectedParts`). */
export function isApprovalCard(question: HomeQuestion, message: HomeMessage, conversation: HomeConversation): boolean {
  if (conversation.owner !== "local") return false;
  const author = conversation.participants.find((person) => person.id === message.author);
  return author?.kind === "agent" && author.chief && approvalDigest(question) !== undefined;
}

/** The card's key (the Swift question id, `<message id>#<part index>`). */
export const approvalKey = (message: HomeMessage, partIndex: number): string => `${message.id}#${partIndex}`;

function sorted(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value).sort()) out[key] = sorted((value as Record<string, unknown>)[key]);
    return out;
  }
  return value;
}

/** The tool's input while the card waits: `toolCall.rawInput` of the allow option's request JSON. */
export function approvalInput(question: HomeQuestion): string | undefined {
  if (question.state.kind !== "pending") return undefined;
  const snapshot = question.items[0]?.options.find((option) => option.id === "allow")?.preview?.text;
  if (!snapshot) return undefined;
  try {
    const request = JSON.parse(snapshot) as { toolCall?: { rawInput?: unknown } };
    const raw = request?.toolCall?.rawInput;
    return raw === undefined ? undefined : JSON.stringify(sorted(raw), null, 2);
  } catch {
    return undefined;
  }
}

/** Where the card stands: the owner's state first, then the page's note while it waits. */
export function approvalStatus(question: HomeQuestion, local: ApprovalLocal | undefined): ApprovalNote | undefined {
  switch (question.state.kind) {
    case "pending":
      return local?.note;
    case "cancelled":
      return "expired";
    case "answered":
      return Object.values(question.state.selections).some((selection) => selection.optionIds.includes("allow"))
        ? "allowed"
        : "denied";
  }
}

/** Buttons show while the question waits and the card has not ended; they take clicks unless busy. */
export const approvalButtons = (question: HomeQuestion, local: ApprovalLocal | undefined) =>
  question.state.kind === "pending" && !local?.ended;

/** Invisible direction and zero-width characters shown as `<U+XXXX>`, so they cannot disguise a command. */
export function visible(text: string): string {
  let out = "";
  for (const char of text) {
    const code = char.codePointAt(0)!;
    const hidden =
      code === 0x061c ||
      code === 0x180e ||
      (code >= 0x200b && code <= 0x200f) ||
      (code >= 0x202a && code <= 0x202e) ||
      (code >= 0x2060 && code <= 0x2069) ||
      code === 0xfeff;
    out += hidden ? `<U+${code.toString(16).toUpperCase().padStart(4, "0")}>` : char;
  }
  return out;
}

/** The app's answer to a decision as the card's state. */
export function parseDecision(answer: unknown): ApprovalLocal {
  const raw = answer && typeof answer === "object" ? (answer as Record<string, unknown>) : {};
  const note = typeof raw.note === "string" && raw.note in APPROVAL_NOTE_KEYS ? (raw.note as ApprovalNote) : "failed";
  return { note, ended: raw.ended === true };
}

/** The cards' state of one transcript, by card key: kept while a card scrolls out of the window. */
export class ApprovalStates {
  private states = new Map<string, ApprovalLocal>();
  private listeners = new Set<() => void>();
  private version = 0;

  get(key: string): ApprovalLocal | undefined {
    return this.states.get(key);
  }

  set(key: string, local: ApprovalLocal): void {
    this.states.set(key, local);
    this.version += 1;
    for (const listener of this.listeners) listener();
  }

  readonly subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  readonly getSnapshot = (): number => this.version;
}

/** What a card's click sends: the app's call (absent with no app: the card shows no buttons). */
export type ApprovalCall = (params: {
  conversation: string;
  message: string;
  seq: number;
  partIndex: number;
  allow: boolean;
}) => Promise<unknown>;

/** The transcript's approvals: its cards' state and the decision a click starts. */
export class ApprovalDecisions {
  readonly states = new ApprovalStates();

  constructor(private readonly call: ApprovalCall) {}

  /** One click on a card: once at a time per card, never after it ended. */
  async decide(message: HomeMessage, partIndex: number, allow: boolean): Promise<void> {
    const key = approvalKey(message, partIndex);
    const now = this.states.get(key);
    if (now?.busy || now?.ended) return;
    this.states.set(key, { busy: true });
    let next: ApprovalLocal;
    try {
      next = parseDecision(
        await this.call({
          conversation: message.conversation,
          message: message.id,
          seq: message.seq,
          partIndex,
          allow,
        }),
      );
    } catch {
      next = { note: "failed" };
    }
    this.states.set(key, next);
  }
}
