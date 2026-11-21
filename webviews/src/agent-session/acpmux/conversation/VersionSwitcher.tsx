// The < n/m > between a prompt's versions (cx-ncc.61; Leo, 2026-11-21: "if you fork or edit in
// claude you can simply click a left or right to go between the variations intra-chat"). Which
// versions a prompt has is read from the chat list (branches.ts); a step opens that version's chat in
// this pane, whose transcript is the same up to the prompt. It draws in two slots, one shown at a
// time by the page's `data-fork-switcher-look` (conversation.css): the footer (the row under the
// bubble, with Copy and Edit) or the head (over the bubble's right edge).
import { useT } from "../i18n";
import { ChevronLeft, ChevronRight, Spinner } from "./icons";
import { ROW_ICON } from "./messageActionsModel";
import type { TurnActions } from "./turnActions";

type Branches = NonNullable<TurnActions["branches"]>;

export function VersionSwitcher({
  branch,
  branches,
  slot,
}: {
  branch: { sessions: string[]; index: number };
  branches: Branches;
  slot: "footer" | "head";
}) {
  const t = useT();
  const total = branch.sessions.length;
  const running = branches.running?.has(branch.sessions[branch.index] ?? "");
  return (
    <span className="cv-user__versions" data-version-slot={slot}>
      <button
        type="button"
        className="cv-iconbtn cv-iconbtn--compact cv-user__version-step"
        aria-label={t("message.previousVersion")}
        title={t("message.previousVersion")}
        disabled={branch.index === 0}
        onClick={() => branches.open(branch.sessions[branch.index - 1]!)}
      >
        <ChevronLeft size={ROW_ICON} />
      </button>
      <span
        className="cv-user__version-count"
        aria-label={t("message.versionCount", { index: branch.index + 1, total })}
        aria-live="polite"
      >
        {running && <Spinner size={12} loading />}
        {branch.index + 1}/{total}
      </span>
      <button
        type="button"
        className="cv-iconbtn cv-iconbtn--compact cv-user__version-step"
        aria-label={t("message.nextVersion")}
        title={t("message.nextVersion")}
        disabled={branch.index === total - 1}
        onClick={() => branches.open(branch.sessions[branch.index + 1]!)}
      >
        <ChevronRight size={ROW_ICON} />
      </button>
    </span>
  );
}
