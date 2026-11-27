// An Auto chat's leftover (plans/cmux-next/auto-mode/DESIGN.md, "Laptop wake"): when the Cloud took
// a chat over while this Mac slept, what this Mac's copy of the agent wrote after the chat moved is
// kept aside instead of merged. The chat's row says so (`autoSession.leftover`), and the person
// picks what happens to it (`_acpmux/auto_session/leftover`): Show it, Apply it to the folder, or
// Discard it.

/// What `_acpmux/auto_session/leftover` does with the kept changes.
export type LeftoverAction = "show" | "apply" | "discard";

/// The kept changes, as Show answers them: the files they touch, and the patch when acpmux sends it.
export type LeftoverShown = { files: string[]; patch?: string };

const path = (value: unknown): string | undefined => {
  if (typeof value === "string") return value || undefined;
  const named = (value as { path?: unknown } | null | undefined)?.path;
  return typeof named === "string" && named ? named : undefined;
};

/// Show's answer: `files` as paths (or `{path}` records) and an optional `patch` text. Anything
/// else is an answer with nothing to list.
export function leftoverShown(reply: unknown): LeftoverShown {
  const answer = (reply && typeof reply === "object" ? reply : {}) as { files?: unknown; patch?: unknown };
  const files = (Array.isArray(answer.files) ? answer.files : []).flatMap((file) => path(file) ?? []);
  return { files, ...(typeof answer.patch === "string" && answer.patch ? { patch: answer.patch } : {}) };
}
