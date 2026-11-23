// The row of extension context chips above the draft (composer/extensionChipsModel.ts reads them). A
// click adds the chip's text at the caret; the row is absent while no extension adds a chip.
import type { PageClient } from "../../../pages/shared/pageClient";
import { useT } from "../i18n";
import { chipTitle, useExtensionChips, type ExtensionChip } from "./extensionChipsModel";

type Props = {
  onPick: (chip: ExtensionChip) => void;
  /// The page client to read the chips through; the page host's by default (a gallery's mock).
  client?: PageClient | null;
};

export function ExtensionChips({ onPick, client }: Props) {
  const t = useT();
  const chips = useExtensionChips(client);
  if (!chips.length) return null;
  return (
    <div className="acpmux-extension-chips" role="toolbar" aria-label={t("composer.extensionChips.label")}>
      {chips.map((chip) => (
        <button
          key={chip.key}
          type="button"
          className="acpmux-extension-chip"
          title={chipTitle(chip) || undefined}
          // A press keeps the prompt's caret where it is, so the text lands there.
          onMouseDown={(event) => event.preventDefault()}
          onClick={() => onPick(chip)}
        >
          {chip.label}
        </button>
      ))}
    </div>
  );
}
