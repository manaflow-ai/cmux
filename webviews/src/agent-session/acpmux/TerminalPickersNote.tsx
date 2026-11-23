import { Icon } from "./icons/Icon";
import { useT } from "./i18n";

/// How the composer row of a chat a cmux terminal runs (Toggle Terminal and Chat) says where its
/// model and mode are set, in place of the chips that cannot apply there
/// (`TerminalPickersNote.gallery.tsx` draws each):
/// - `sentence`: the whole sentence where the chips stood. Long: it crowds the row and cuts first
///   in a narrow pane.
/// - `badge`: a quiet terminal glyph and "Set in terminal" where the chips stood, the chips'
///   height and inset, the sentence as its tooltip and accessible description. Not a control: no
///   hover wash, nothing to press.
/// - `trailing`: the same badge at the row's trailing side, where the reference composers keep the
///   model (Claude's "Opus 5.5 Medium", Codex's model chip), right before Stop and Send.
export type TerminalPickersLook = "sentence" | "badge" | "trailing";

/// The picked look (design/terminal-chat-toggle.md, "Composer row"): `badge`. It keeps the row's
/// left column (+, then what stands for the chips) as every chat has it, takes one chip's room, and
/// reads at a glance; the trailing side stays Stop, mic and Send alone, so nothing moves there.
export const TERMINAL_PICKERS_LOOK: TerminalPickersLook = "badge";

export function TerminalPickersNote({ look = TERMINAL_PICKERS_LOOK }: { look?: TerminalPickersLook }) {
  const t = useT();
  const why = t("watch.terminalPickers");
  if (look === "sentence") {
    return (
      <span className="acpmux-terminal-pickers" data-terminal-pickers="" data-look={look}>
        {why}
      </span>
    );
  }
  return (
    <span
      className="acpmux-terminal-pickers"
      data-terminal-pickers=""
      data-look={look}
      title={why}
      aria-description={why}
    >
      <Icon name="terminal" size={14} row />
      <span className="acpmux-terminal-pickers-label">{t("watch.terminalPickersShort")}</span>
    </span>
  );
}
