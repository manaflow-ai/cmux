// A first-open repo tour (wow #8, hq docs/strategy/2026-11-08-wow-ideas.md): a new chat in a folder
// no chat has used yet offers a tour, never runs one by itself. Take the tour sends TOUR_PROMPT; the
// agent answers with one closed ```cmux-tour fence (a JSON object), which the transcript draws as a
// TourCard: what the project is, its main modules as path chips, how to run it, and three first
// tasks, each with Start (chat.tour.start: a new worktree and a chat with the task).
//
// The tour is cached per repository head by the agent itself: it saves the fence under the git
// common folder, which every worktree of the repository shares, by HEAD's sha. A second tour at the
// same commit, in any worktree, prints the saved one instead of reading the repository again.
import { isAgentHome } from "../sessionList";
import { TOUR_ASK, TOUR_FENCE } from "./tourPrompt";

export { TOUR_ASK, TOUR_FENCE, TOUR_PROMPT } from "./tourPrompt";

export type TourModule = { path: string; about: string };
export type TourCommand = { command: string; about?: string };
export type TourTask = { title: string; prompt: string };
export type Tour = {
  head?: string;
  summary: string;
  modules: TourModule[];
  run: TourCommand[];
  tasks: TourTask[];
};

const MAX_MODULES = 8;
const MAX_COMMANDS = 4;
const MAX_TASKS = 3;

const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() ? value.trim() : undefined;

function items<T>(value: unknown, max: number, read: (item: Record<string, unknown>) => T | undefined): T[] {
  if (!Array.isArray(value)) return [];
  const out: T[] = [];
  for (const item of value) {
    if (out.length === max) break;
    if (!item || typeof item !== "object") continue;
    const read_ = read(item as Record<string, unknown>);
    if (read_) out.push(read_);
  }
  return out;
}

/// A module's path as the chips take it (chips/paths.ts): from the folder, `./`-led, so a bare
/// `src/app` still chips; an absolute or `~/` path stays as written.
export function chipPath(path: string): string {
  if (path.startsWith("/") || path.startsWith("~/") || path.startsWith("./") || path.startsWith("../")) return path;
  return `./${path}`;
}

/// The tour in a closed fence's code, or nothing when it is not one: a reply that is not the
/// promised JSON draws as the code it is.
export function parseTour(lang: string, code: string): Tour | undefined {
  if (lang.trim().toLowerCase() !== TOUR_FENCE) return undefined;
  let value: unknown;
  try {
    value = JSON.parse(code);
  } catch {
    return undefined;
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const raw = value as Record<string, unknown>;
  const summary = text(raw.summary);
  if (!summary) return undefined;
  const modules = items(raw.modules, MAX_MODULES, (item) => {
    const path = text(item.path);
    return path ? { path: chipPath(path), about: text(item.about) ?? "" } : undefined;
  });
  const run = items(raw.run, MAX_COMMANDS, (item) => {
    const command = text(item.command);
    const about = text(item.about);
    return command ? { command, ...(about ? { about } : {}) } : undefined;
  });
  const tasks = items(raw.tasks, MAX_TASKS, (item) => {
    const title = text(item.title);
    const prompt = text(item.prompt);
    return title && prompt ? { title, prompt } : undefined;
  });
  const head = text(raw.head);
  return { ...(head && /^[0-9a-f]{7,64}$/i.test(head) ? { head } : {}), summary, modules, run, tasks };
}

const trimmed = (folder: string) => folder.replace(/(.)\/+$/, "$1");

/// Whether a new chat in `cwd` offers the tour: a project folder on this Mac that no other chat in
/// the daemon's list has used, once that list has answered, and that the person did not dismiss.
export function offersTour({
  cwd,
  local,
  listed,
  sessions,
  sessionId,
  dismissed,
}: {
  cwd: string | undefined;
  /// The chat runs on this Mac (no peer or Cloud host).
  local: boolean;
  /// The daemon listed its chats to this page: an unlisted folder is not yet known to be new.
  listed: boolean;
  sessions: readonly { sessionId: string; cwd?: unknown; peer?: string; hostKind?: string }[];
  /// This chat's own entry, which never makes its folder seen.
  sessionId?: string;
  dismissed: (folder: string) => boolean;
}): boolean {
  if (!local || !listed || !cwd?.startsWith("/") || isAgentHome(cwd)) return false;
  const folder = trimmed(cwd);
  if (/^\/(?:(?:Users|home)(?:\/[^/]+)?)?$/.test(folder)) return false;
  if (dismissed(folder)) return false;
  return !sessions.some(
    (session) =>
      session.sessionId !== sessionId &&
      !session.peer &&
      session.hostKind !== "cloud" &&
      typeof session.cwd === "string" &&
      trimmed(session.cwd) === folder,
  );
}

const DISMISSED_KEY = "cmux.acpmux.repoTour.dismissed.v1";
/// The most folders the dismissed list keeps (oldest dropped): the list never grows without bound.
const DISMISSED_MAX = 200;

function storage(): Storage | undefined {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}

function readDismissed(): string[] {
  try {
    const parsed: unknown = JSON.parse(storage()?.getItem(DISMISSED_KEY) ?? "[]");
    return Array.isArray(parsed) ? parsed.filter((entry): entry is string => typeof entry === "string") : [];
  } catch {
    return [];
  }
}

/// The person closed the offer for this folder. The page's storage ends with the launch; a folder
/// a chat then used is seen anyway, so the offer only comes back for a folder still never used.
export function isTourDismissed(folder: string): boolean {
  return readDismissed().includes(trimmed(folder));
}

export function dismissTour(folder: string): void {
  const kept = readDismissed().filter((entry) => entry !== trimmed(folder));
  kept.push(trimmed(folder));
  try {
    storage()?.setItem(DISMISSED_KEY, JSON.stringify(kept.slice(-DISMISSED_MAX)));
  } catch {
    // A page with no storage keeps showing the offer; it is quiet, and a send ends it.
  }
}

/// A sent tour prompt's bubble shows its first line only: the rest is instructions to the agent.
export function tourBubbleText(text: string): string | undefined {
  return text.startsWith(`${TOUR_ASK}\n`) && text.includes(`\`\`\`${TOUR_FENCE}`) ? TOUR_ASK : undefined;
}
