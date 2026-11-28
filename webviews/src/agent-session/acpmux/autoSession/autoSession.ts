// Auto mode (plans/cmux-next/auto-mode/DESIGN.md): a chat with Auto on keeps running on the person's
// Cloud machine when this Mac sleeps or goes offline, and comes back when the Mac returns. acpmux
// says where each chat stands on its row (`autoSession`); this file reads that field and decides
// what the pane says about it. A row without the field is a chat of an acpmux that predates Auto:
// the pane draws and offers nothing new for it.
//
// No surface says how it works (who holds the chat, its copy in the Cloud): only where the chat
// runs, and the one thing the person can do when it cannot.

/// Where an Auto chat stands, as the Cloud sees it.
export type AutoState = "local" | "cloud" | "resuming" | "parked" | "coming_back";
const STATES: readonly string[] = ["local", "cloud", "resuming", "parked", "coming_back"];

/// Why Auto cannot keep the chat going in the Cloud.
export type AutoBlocked = "no_machine" | "too_large" | "offline";
const BLOCKED: readonly string[] = ["no_machine", "too_large", "offline"];

/// A chat's `autoSession`, as acpmux sends it on the chat's row.
export type AutoSession = {
  /// Auto is on for this chat.
  auto: boolean;
  state: AutoState;
  /// This Mac runs the chat now.
  here: boolean;
  /// The person asked for the chat to stay in the Cloud when this Mac returns.
  keepInCloud: boolean;
  blocked?: AutoBlocked;
  /// Changes this Mac made after the chat moved to the Cloud, kept aside: how many files.
  leftover?: { files: number };
};

/// How many files a `leftover` names: acpmux's `files` as a count, or as the list of their paths.
function leftoverFiles(value: unknown): number | undefined {
  if (!value || typeof value !== "object") return undefined;
  const files = (value as { files?: unknown }).files;
  if (Array.isArray(files)) return files.length;
  return typeof files === "number" && Number.isFinite(files) && files >= 0 ? Math.floor(files) : 0;
}

const same = (a: AutoSession, b: AutoSession) =>
  a.auto === b.auto &&
  a.state === b.state &&
  a.here === b.here &&
  a.keepInCloud === b.keepInCloud &&
  a.blocked === b.blocked &&
  a.leftover?.files === b.leftover?.files;

/// A row's `autoSession`, or undefined when the row has none (an acpmux without Auto) or it is not
/// one. An unknown `state` reads as `local` and an unknown `blocked` as none, so a newer acpmux's
/// word draws nothing rather than something wrong. `previous` comes back when nothing changed, so
/// a snapshot built from the same row keeps the same object.
export function autoSessionOf(value: unknown, previous?: AutoSession): AutoSession | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const row = value as Record<string, unknown>;
  if (typeof row.auto !== "boolean") return undefined;
  const state = (STATES.includes(row.state as string) ? row.state : "local") as AutoState;
  const files = leftoverFiles(row.leftover);
  const next: AutoSession = {
    auto: row.auto,
    state,
    // A row that does not say is this Mac's while the Cloud does not run it.
    here: typeof row.here === "boolean" ? row.here : state === "local",
    keepInCloud: row.keepInCloud === true,
    ...(BLOCKED.includes(row.blocked as string) ? { blocked: row.blocked as AutoBlocked } : {}),
    ...(files !== undefined ? { leftover: { files } } : {}),
  };
  return previous && same(previous, next) ? previous : next;
}

/// Whether the Cloud runs the chat (or is starting to): what "Keep in Cloud" applies to.
export function heldInCloud(auto: AutoSession | undefined): boolean {
  if (!auto?.auto || auto.here) return false;
  return auto.state === "cloud" || auto.state === "resuming" || auto.state === "coming_back";
}

/// The one line the pane says about an Auto chat, or none.
export type AutoLine =
  | { kind: "cloud" }
  | { kind: "resuming" }
  | { kind: "comingBack" }
  | { kind: "blocked"; blocked: AutoBlocked };

/// What an Auto chat's line says. A chat this Mac runs says nothing new; one the Cloud runs says so;
/// one on its way to the Cloud says Resuming; one due home says it comes back at the end of the
/// turn. A chat nobody runs (`parked`) says nothing until the person sends (`sending`: a prompt
/// waits or a turn runs), then Resuming. What stops Auto (`blocked`) is one line with its action,
/// and comes first: it is the only state the person can change.
export function autoLine(auto: AutoSession | undefined, sending: boolean): AutoLine | undefined {
  if (!auto?.auto) return undefined;
  if (auto.blocked) return { kind: "blocked", blocked: auto.blocked };
  switch (auto.state) {
    case "cloud":
      return { kind: "cloud" };
    case "resuming":
      return { kind: "resuming" };
    case "coming_back":
      return { kind: "comingBack" };
    case "parked":
      return sending ? { kind: "resuming" } : undefined;
    default:
      return undefined;
  }
}

/// Whether anything of Auto sits under the chat's header (header/underHeader.ts): its line, or the
/// notice of changes kept aside, which stays until the person applies or discards them whether or
/// not Auto is still on.
export function autoUnderHeader(auto: AutoSession | undefined, sending: boolean): boolean {
  return auto !== undefined && (auto.leftover !== undefined || autoLine(auto, sending) !== undefined);
}

/// JSON-RPC's "Method not found": an acpmux that predates Auto answers it to every Auto request.
const METHOD_NOT_FOUND = -32601;

/// Whether `error` is an acpmux that does not know the Auto methods. The pane then offers nothing
/// and says nothing, as before Auto. A refusal by the cmux host carries the same code with
/// `data.origin: "native"` (AcpmuxPaneMethods.swift `refusal`): that one is a failure to say.
export function autoUnsupported(error: unknown): boolean {
  const failure = error as { code?: unknown; data?: { origin?: unknown }; origin?: unknown } | null | undefined;
  if (failure?.code !== METHOD_NOT_FOUND) return false;
  return failure.data?.origin !== "native" && failure.origin !== "native";
}
