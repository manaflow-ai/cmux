// l10n-allow-file: gallery design fixtures for a folderless Cloud chat's folder chip, not shipped UI.
// Designs of the folder chip while Cloud is the pick and no folder is (folderlessCloud.ts), side by
// side in the gallery around the real scope row. Only `menu-note` ships: No folder on the chip, its
// one line of detail in the folder menu and as the chip's description. The others restyle the same
// chip with CSS here alone, so the choice is made on what each looks like. Leo, 2026-11-09: "We need
// to be able to have it so, like, this no folder selected should be, like, good as well."
import type { ComponentProps } from "react";
import { ComposerContext } from "./ComposerContext";

/// `menu-note` (shipped): "No folder", the detail in the menu. `inline-detail`: the detail after the
/// label in the strip. `fresh-home`: the chip names the place ("Fresh home") instead of the absence.
/// `before`: the empty "Choose folder" Leo saw, for comparison.
export type CloudFolderlessDesign = "menu-note" | "inline-detail" | "fresh-home" | "before";

export type CloudFolderlessDesignsProps = ComponentProps<typeof ComposerContext> & { design: CloudFolderlessDesign };

const LABEL = '.acpmux-location-label[data-folder-state="cloudFresh"]';
/// `fresh-home` and `before` change the label's words, which the gallery's play does
/// (CloudFolderlessDesigns.gallery.tsx `relabel`); only `inline-detail` needs a style.
const STYLES: Record<CloudFolderlessDesign, string> = {
  "menu-note": "",
  "inline-detail": `${LABEL}::after { content: " · fresh home on the machine"; color: var(--agent-muted); }`,
  "fresh-home": "",
  before: "",
};

export function CloudFolderlessDesigns({ design, ...props }: CloudFolderlessDesignsProps) {
  return (
    <>
      {STYLES[design] && <style>{STYLES[design]}</style>}
      <ComposerContext {...props} />
    </>
  );
}
