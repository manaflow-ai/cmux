export const handoffStrings = {
  transcript: "Transcript",
  tool_output: "Tool output",
  plan: "Plan",
  files: "Files",
  model: "Model",
  included: "Included",
  summarized: "Summarized",
  omitted: "Omitted",
  unavailable: "Unavailable",
  continueIn: "Continue in…",
  review: "Review continuation",
  fromTo: "Continue from %@ in %@",
  context: "Context to carry forward",
  checkpoint: "Repository checkpoint",
  checkpointPlaceholder: "A saved commit, stash, or backup reference",
  checkpointConfirm: "I saved the working changes, including the files I need to keep.",
  memory: "Approved memory references",
  memoryHelp: "Share only the references you approve for this chat, one per line.",
  starting: "Starting…",
  continueTarget: "Continue in %@",
  returnSource: "Back to source chat",
  discard: "Discard continuation",
  saving: "Saving review…",
  reload: "Reload saved review",
  coverage: "Carried context",
  source: "Source chat",
  target: "Target chat",
  nativePolicy: "Native policy · isolation unverified",
  unverified: "Coverage unverified",
  unverifiedDetail: "Filesystem and network isolation have not been verified for this session.",
  reviewContext: "Review the context before continuing.",
  tooLarge: "Keep the context below %@ bytes.",
  saveCheckpoint: "Save a repository checkpoint before continuing.",
  checkpointSingle: "Use a single checkpoint reference.",
  memoryLimit: "Use at most 32 memory references, one per line.",
  failedReview: "Couldn’t review this continuation.",
};
export type HandoffStrings = typeof handoffStrings;
export function localizedHandoffStrings(value: unknown): HandoffStrings {
  const strings = { ...handoffStrings };
  if (value && typeof value === "object")
    for (const key of Object.keys(strings) as (keyof HandoffStrings)[]) {
      const translated = (value as Record<string, unknown>)[key];
      if (typeof translated === "string" && translated.trim()) strings[key] = translated;
    }
  return strings;
}
export function formatHandoff(value: string, ...args: string[]): string {
  let index = 0;
  return value.replace(/%@/g, () => args[index++] ?? "");
}
