// l10n-allow-file: type specimens and column labels, gallery only, not shipped UI.
// Proof stills for Quillet, our own type family (fonts/OFL-Quillet.txt): each sample drawn in the
// system font, the Folio stand-ins (Hanken Grotesk, Newsreader and JetBrains Mono under made-up names,
// chatFonts/FontPack.gallery.ts) and Quillet, at 13, 15 and 17 px; the gallery's light and dark
// schemes give both appearances. Leo, 2026-11-18: "you know with the font packs earlier i was implying
// we can make our own...". Off a Mac the system column draws the gallery's SF stand-in
// (frame/systemFontStandIn.ts) and the system mono column the host's own monospace.
import { componentEntry } from "../format";
import type { Play } from "../play";
import type { ProofColumn, QuilletProofProps } from "./QuilletProof";
import { FACES, type FaceKey } from "./candidates";

const SYSTEM = "-apple-system, BlinkMacSystemFont, system-ui, sans-serif";
const SYSTEM_MONO = 'ui-monospace, "SF Mono", Menlo, monospace';

const SANS: ProofColumn[] = [
  { label: "System", system: SYSTEM },
  { label: "Folio Sans (Hanken Grotesk)", face: "hanken" },
  { label: "Quillet Sans", face: "quilletSans" },
];
const SERIF: ProofColumn[] = [
  { label: "System (today's replies)", system: SYSTEM },
  { label: "Folio Serif (Newsreader)", face: "newsreader" },
  { label: "Quillet Serif", face: "quilletSerif" },
];
const MONO: ProofColumn[] = [
  { label: "System mono", system: SYSTEM_MONO },
  { label: "Folio Mono (JetBrains Mono)", face: "jetbrains" },
  { label: "Quillet Mono", face: "quilletMono" },
];

/// The stage is ready once every study face the columns name has loaded, so no still shows a fallback.
const facesLoaded =
  (columns: ProofColumn[]): Play =>
  async (ctx) => {
    const families = columns.flatMap((column) => (column.face ? [FACES[column.face as FaceKey].family] : []));
    await Promise.all(families.map((family) => ctx.document.fonts.load(`400 15px "${family}"`)));
    await ctx.waitFor(
      () =>
        families.every((family) => ctx.document.fonts.check(`400 15px "${family}"`)) &&
        ctx.document.fonts.status === "loaded",
    );
  };

const variant = (note: string, props: QuilletProofProps, height: number) => ({
  note,
  props,
  height,
  play: facesLoaded(props.columns),
});

export default componentEntry<QuilletProofProps>({
  id: "font-study.quillet-proof",
  title: "Quillet proof: our type family beside the system font and the Folio stand-ins",
  area: "Agent pane",
  height: 900,
  widths: { narrow: 960, normal: 1200, wide: 1440 },
  covers: ["gallery/fontStudy/QuilletProof.tsx#QuilletProof"],
  keywords: ["font", "typeface", "typography", "quillet", "folio", "font pack", "specimen", "proof"],
  load: async () => (await import("./QuilletProof")).QuilletProof,
  variants: {
    "body-serif": variant(
      "Reply prose at 13, 15 and 17 px on 1.6: the system font, Folio Serif and Quillet Serif.",
      { sample: "body", columns: SERIF },
      680,
    ),
    "body-sans": variant(
      "Chat body text at 13, 15 and 17 px on 1.6: the system font, Folio Sans and Quillet Sans.",
      { sample: "body", columns: SANS },
      680,
    ),
    "ui-rows": variant(
      "Sidebar rows (titles, captions two px smaller, badges) at 13, 15 and 17 px: the system font, Folio Sans and Quillet Sans.",
      { sample: "rows", columns: SANS },
      1060,
    ),
    code: variant(
      "Code at 0.875 of 13, 15 and 17 px: the system mono, Folio Mono and Quillet Mono.",
      { sample: "code", columns: MONO },
      1160,
    ),
  },
});
