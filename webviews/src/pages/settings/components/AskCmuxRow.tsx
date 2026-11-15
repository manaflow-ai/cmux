// A search no setting matches is a wish: the same box hands the words to the Customize chat
// (`customize.open`, cmux#43304), whose agent changes cmux while the person watches. Leo,
// 2026-11-14: "ultra braindead and/or asking agents to just do stuff add stuff etc".
import { Icon } from "../icons";
import { t } from "../strings";

/** The gallery's three looks; `row` ships. */
export type AskCmuxLook = "row" | "button" | "link";

export function AskCmuxRow({ words, look = "row", onAsk }: { words: string; look?: AskCmuxLook; onAsk: () => void }) {
  return (
    <button type="button" className="ask-cmux" data-look={look} data-ask-cmux="" onClick={onAsk}>
      <Icon name="wand.and.stars" />
      <span className="ask-cmux-text">
        <span className="ask-cmux-title">{t("settingsPage.askCmux")}</span>
        <span className="ask-cmux-words">{words.trim()}</span>
      </span>
      <Icon name="arrow.turn.down.right" />
    </button>
  );
}
