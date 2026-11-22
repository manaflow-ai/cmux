// The continuation review's labels: keys of the pane's string table (handoff.*, acpmux/Localizable.xcstrings), in
// every shipped language, so English is never a fallback the user sees.
import { type StringKey, type Translate, translate } from "../i18n";

const HANDOFF_KEYS = {
  transcript: "handoff.transcript",
  tool_output: "handoff.tool_output",
  plan: "handoff.plan",
  files: "handoff.files",
  model: "handoff.model",
  included: "handoff.included",
  summarized: "handoff.summarized",
  omitted: "handoff.omitted",
  unavailable: "handoff.unavailable",
  continueIn: "handoff.continueIn",
  review: "handoff.review",
  fromTo: "handoff.fromTo",
  context: "handoff.context",
  checkpoint: "handoff.checkpoint",
  checkpointPlaceholder: "handoff.checkpointPlaceholder",
  checkpointConfirm: "handoff.checkpointConfirm",
  memory: "handoff.memory",
  memoryHelp: "handoff.memoryHelp",
  starting: "handoff.starting",
  continueTarget: "handoff.continueTarget",
  returnSource: "handoff.returnSource",
  discard: "handoff.discard",
  saving: "handoff.saving",
  reload: "handoff.reload",
  coverage: "handoff.coverage",
  source: "handoff.source",
  target: "handoff.target",
  nativePolicy: "handoff.nativePolicy",
  unverified: "handoff.unverified",
  unverifiedDetail: "handoff.unverifiedDetail",
  reviewContext: "handoff.reviewContext",
  tooLarge: "handoff.tooLarge",
  saveCheckpoint: "handoff.saveCheckpoint",
  checkpointSingle: "handoff.checkpointSingle",
  memoryLimit: "handoff.memoryLimit",
  failedReview: "handoff.failedReview",
} as const satisfies Record<string, StringKey>;

export type HandoffStrings = Record<keyof typeof HANDOFF_KEYS, string>;

/** The labels in the pane's language (`t` from `useT()` in render; the current language otherwise). */
export function handoffStrings(t: Translate = translate): HandoffStrings {
  return Object.fromEntries(Object.entries(HANDOFF_KEYS).map(([name, key]) => [name, t(key)])) as HandoffStrings;
}

export function formatHandoff(value: string, ...args: string[]): string {
  let index = 0;
  return value.replace(/%@/g, () => args[index++] ?? "");
}
