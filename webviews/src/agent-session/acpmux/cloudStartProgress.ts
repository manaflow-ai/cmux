import type { CloudStartAnswer } from "./cloudRun";

/// A chat starting in Cloud, as the chat shows it (CloudStartView; cloud work mode, leo-workspace
/// design/cloud-work-mode.md): while the host's `cloud.startChat` runs (a new machine boots in
/// minutes), the new chat shows the person's message and how the start goes as metadata under it:
/// the step it is on, the folder it copies, the machine, the secrets the machine gets and its
/// network. Never a sheet or a modal, and no Full Access warning: the chat runs on the machine.
///
/// The page knows the message and the folder from the send. The rest comes from the host as it
/// learns it (`cloudStartProgress` on the page bridge, keyed by the start's `key`), the folder too
/// when the send named none (the host copies the tab's own); a host that sends none leaves the card
/// at "Starting in Cloud". A start that succeeds closes
/// this tab (the chat is the machine's), so the card has no done state; a failure shows the host's
/// words, and the message stays in the composer for another send.

/// Where a start is, in order: a machine taken or booted, the folder copied, the chat opened.
export const CLOUD_START_STEPS = ["machine", "folder", "opening"] as const;
export type CloudStartStep = (typeof CLOUD_START_STEPS)[number];

export type CloudStartProgress = {
  /// The start's key (`cloud.startChat {key}`): a push for another start is dropped.
  key: string;
  /// The person's message.
  task: string;
  state: "starting" | "failed";
  /// The folder's name (its last path part).
  folder?: string;
  step?: CloudStartStep;
  /// The machine's name, and its size as the host words it ("4 CPU, 16 GB").
  machine?: string;
  size?: string;
  /// How many of the account's secrets the machine gets.
  secrets?: number;
  /// The machine's network: the open internet, or only what its policy allows.
  network?: "full" | "limited";
  /// A failure's words, the host's own.
  message?: string;
  /// The agent the chat starts, by name ("Claude Code"), for the opening step.
  agent?: string;
  /// No project: nothing is copied, so the card shows no copy step.
  home?: boolean;
};

/// The start the page just sent: the message, and the folder by its name.
export function cloudStartBegun(
  key: string,
  task: string,
  cwd: string | undefined,
  agent?: string,
  home?: boolean,
): CloudStartProgress {
  const folder = cwd?.replace(/\/+$/, "").split("/").pop();
  return {
    key,
    task,
    state: "starting",
    ...(folder ? { folder } : {}),
    ...(agent ? { agent } : {}),
    ...(home ? { home: true } : {}),
  };
}

/// Text the card shows from the host: one line, at most `max` characters.
function line(value: unknown, max: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = value.replace(/\s+/g, " ").trim();
  return text ? (text.length > max ? `${text.slice(0, max - 1)}…` : text) : undefined;
}

/// `current` with the host's push `push` taken in: only for the same start while it runs, field by
/// field, each checked (anything else in it is ignored). A step never goes back.
export function cloudStartPushed(
  current: CloudStartProgress | undefined,
  push: unknown,
): CloudStartProgress | undefined {
  if (!current || current.state !== "starting" || typeof push !== "object" || push === null) return current;
  const fields = push as Record<string, unknown>;
  if (fields.key !== current.key) return current;
  const next = { ...current };
  const step = CLOUD_START_STEPS.indexOf(fields.step as CloudStartStep);
  if (step >= 0 && step >= (current.step ? CLOUD_START_STEPS.indexOf(current.step) : -1))
    next.step = CLOUD_START_STEPS[step];
  const folder = line(fields.folder, 64);
  if (folder && !folder.includes("/")) next.folder = folder;
  const machine = line(fields.machine, 64);
  if (machine) next.machine = machine;
  const size = line(fields.size, 32);
  if (size) next.size = size;
  if (typeof fields.secrets === "number" && Number.isSafeInteger(fields.secrets) && fields.secrets >= 0)
    next.secrets = fields.secrets;
  if (fields.network === "full" || fields.network === "limited") next.network = fields.network;
  return next;
}

/// `current` once the host answered start `key`: none when the chat opened on the machine (this tab
/// closes), failed with the host's words when it didn't. Another start's answer changes nothing.
export function cloudStartEnded(
  current: CloudStartProgress | undefined,
  key: string,
  answer: CloudStartAnswer,
): CloudStartProgress | undefined {
  if (current?.key !== key) return current;
  if (answer.ok) return undefined;
  const message = line(answer.message, 240);
  return { ...current, state: "failed", ...(message ? { message } : {}) };
}
