// The row of extension context chips over the prompt (composer/extensionChipModel.ts). It draws only
// when an installed extension offers a chip, so with none the composer is unchanged.
import { memo } from "react";
import type { ExtensionChip } from "./extensionChipModel";

export const ExtensionChips = memo(function ExtensionChips({
  chips,
  onPick,
}: {
  chips: readonly ExtensionChip[];
  onPick: (chip: ExtensionChip) => void;
}) {
  if (!chips.length) return null;
  return (
    <div className="acpmux-extension-chips" role="toolbar" data-extension-chips={chips.length}>
      {chips.map((chip) => (
        <button
          key={`${chip.app}/${chip.id}`}
          type="button"
          className="acpmux-extension-chip"
          data-chip-app={chip.app}
          data-chip-id={chip.id}
          title={chip.detail ?? chip.insert}
          // A click keeps the prompt's caret and focus: the text goes where the person was typing.
          onMouseDown={(event) => event.preventDefault()}
          onClick={() => onPick(chip)}
        >
          {chip.label}
        </button>
      ))}
    </div>
  );
});
