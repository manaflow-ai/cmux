// New project on the New Tab (Leo, 2026-11-08: things people would think "wow this is awesome"):
// the person types what to build, acpmux makes the folder and its empty git repository
// (`_acpmux/project_new`, server/project_new.rs), the chat starts there with the prompt, and the
// first local page the chat serves opens beside it (App.tsx, takeProjectPreview).

/// The longest name derived from a prompt; acpmux takes up to 64.
const NAME_MAX = 40;
/// The words a prompt opens with that name no part of the project ("build me a", "make an").
const LEAD =
  /^(?:(?:please|pls|can you|could you|let's|lets|i want to|i'd like to|help me)\s+)*(?:(?:build|make|create|write|start|scaffold|set up|setup|code)\s+)?(?:me\s+)?(?:(?:a|an|the|my|some)\s+)?/i;
/// Words that end the name: what comes after is detail ("a habit tracker with streaks").
const STOP = new Set(["with", "that", "which", "where", "using", "in", "for", "on", "to", "and", "so"]);
/// Never in the name: what is left of a lead that named nothing ("build me a").
const SKIP = new Set(["a", "an", "the", "me", "my", "some"]);
/// Kept out of the name: they say what kind of thing it is, which every project is.
const FILLER = new Set(["web", "app", "application", "website", "site", "simple", "small", "little", "new", "basic"]);

/// A folder name acpmux takes (letters, digits, `.`, `_`, `-`; no leading `.` or `-`), from what the
/// person typed as the name: lower case, other runs of characters as one `-`.
export function projectSlug(text: string, max = 64): string {
  return text
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9._]+/g, "-")
    .replace(/^[-.]+/, "")
    .slice(0, max)
    .replace(/[-.]+$/, "");
}

/// The name field as it is typed: the characters a folder name takes, others as `-`, lower case;
/// the ends are trimmed only at the send (projectSlug), so a `-` can be typed between words.
export function projectNameTyping(text: string): string {
  return text
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^[-.]+/, "")
    .slice(0, 64);
}

/// The project's name from its prompt: "a habit tracker web app" is `habit-tracker`. Up to four
/// words before the detail starts; the kind words go unless they are all there is. "project" when
/// the prompt names nothing.
export function projectNameFrom(prompt: string): string {
  // The first sentence: a dot ends one only before a space or the end ("Next.js" stays whole).
  const first = prompt.split(/\n|[.!?](?:\s|$)/, 1)[0] ?? "";
  const words = first.replace(LEAD, "").split(/\s+/).filter(Boolean);
  const kept: string[] = [];
  for (const word of words) {
    const plain = word
      .toLowerCase()
      .replace(/[^\p{L}\p{N}.-]/gu, "")
      .replace(/^\.+|\.+$/g, "");
    if (!plain || SKIP.has(plain)) continue;
    if (STOP.has(plain)) {
      if (kept.length > 0) break;
      continue;
    }
    kept.push(plain);
    if (kept.length === 4) break;
  }
  const named = kept.filter((word) => !FILLER.has(word));
  return projectSlug((named.length > 0 ? named : kept).join(" "), NAME_MAX) || "project";
}

/// What the chat is asked with: the person's words, then one line that says the folder is new and
/// that the page it serves opens by itself once it says where.
export function newProjectPrompt(prompt: string): string {
  // l10n-allow: text for the agent, sent in the prompt, not UI.
  return `${prompt.trimEnd()}\n\n(This is a new, empty project folder with a git repository. Build it here, start its dev server in the background, and give me its local URL once it serves.)`;
}

// The folders whose chat opens its first local page beside it. One page holds them: the New Tab
// becomes the chat in the same page (screenActions.ts `leave`). A folder leaves when its page opens
// or after its deadline, so a chat that never serves one keeps nothing.
const PREVIEW_DEADLINE_MS = 30 * 60_000;
const waiting = new Map<string, number>();

/// The chat started in `folder` opens its first local page beside it.
export function awaitProjectPreview(folder: string, now = Date.now()): void {
  waiting.set(folder, now + PREVIEW_DEADLINE_MS);
}

/// Whether the chat in `folder` still opens its first page; true once, then never again.
export function takeProjectPreview(folder: string | undefined, now = Date.now()): boolean {
  if (!folder) return false;
  const until = waiting.get(folder);
  if (until === undefined) return false;
  waiting.delete(folder);
  return until >= now;
}

/// The chat in `folder` did not start: no later chat there opens its page.
export function forgetProjectPreview(folder: string | undefined): void {
  if (folder) waiting.delete(folder);
}

/// Whether a chat in `folder` still waits for its page (no taking).
export function awaitsProjectPreview(folder: string | undefined, now = Date.now()): boolean {
  if (!folder) return false;
  const until = waiting.get(folder);
  if (until !== undefined && until < now) waiting.delete(folder);
  return until !== undefined && until >= now;
}
