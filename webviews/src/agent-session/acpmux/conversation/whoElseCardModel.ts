import { type Translate } from "../i18n";
import { type WhoElseSession } from "./whoElseCalls";

/// Files listed per row; the count says the rest.
const FILES_SHOWN = 3;

/// What the session has in common: `edited a.rs, b.rs · read c.rs · +2 more`, or why it matched.
export function whatText(t: Translate, s: WhoElseSession): string {
  const base = (path: string) => path.split("/").pop() ?? path;
  const edited = s.files.filter((f) => f.edited).slice(0, FILES_SHOWN);
  const read = s.files.filter((f) => !f.edited).slice(0, Math.max(0, FILES_SHOWN - edited.length));
  const parts: string[] = [];
  if (edited.length) parts.push(t("whoElse.edited", { files: edited.map((f) => base(f.path)).join(", ") }));
  if (read.length) parts.push(t("whoElse.read", { files: read.map((f) => base(f.path)).join(", ") }));
  const rest = s.filesInCommon - edited.length - read.length;
  if (rest > 0) parts.push(t("whoElse.more", { count: String(rest) }));
  if (s.sameWorktree) parts.push(t("whoElse.sameWorktree"));
  if (s.sameBranch) parts.push(t("whoElse.sameBranch"));
  if (s.topicWords.length) parts.push(t("whoElse.topic", { words: s.topicWords.join(", ") }));
  return parts.join(" · ");
}
