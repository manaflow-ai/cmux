// l10n-allow-file: type specimens and labels, gallery only, not shipped UI.
// The family swap: Quillet, the cmux family (cmux Sans, cmux Serif and cmux Mono) and the system font
// drawing the same transcript lines, one family at a time, swapped by a press. The stage's anchor check
// fails if any line moves or resizes on a swap (play.ts, strict by default), so a passing variant is the
// 0 px line-shift proof in a browser, beside scripts/fonts/family/check.py's on the files. Leo, 2026-11-19:
// "quillet is our anthropic inspired one. we do want our own separate one!" and "cmux sans/manaflow sans".
// The cmux family shares Quillet's line box (960 / -240 of 1000) by design, and it draws at Selvedge (`WEFT`)
// 0, plain faces: the axis stays in the fonts at its default, with no variant here (Leo: "selvege is kinda ugly").
import { componentEntry } from "../format";
import type { Play } from "../play";
import type { FamilySwapProps, SwapFamily } from "./FamilySwap";
import { FACES, type FaceKey } from "./candidates";

const SYSTEM: SwapFamily = {
  label: "System",
  sans: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif",
  serif: '"New York", ui-serif, Georgia, serif',
  display: '"New York", ui-serif, Georgia, serif',
  mono: 'ui-monospace, "SF Mono", Menlo, monospace',
};
const QUILLET: SwapFamily = {
  label: "Quillet",
  sans: "quilletSans",
  serif: "quilletSerif",
  display: "quilletSerif",
  mono: "quilletMono",
};
const CMUX: SwapFamily = {
  label: "cmux Sans, Serif, Mono",
  sans: "cmuxFamilySans",
  serif: "cmuxFamilySerif",
  display: "cmuxFamilyDisplay",
  mono: "cmuxFamilyMono",
};

const ROWS = ["reply", "title", "mixed", "code", "display", "after"];

/// Loads every study face first (so no swap is a font load), then presses Swap family once per family
/// after the first; each press is a measured step and every row is an anchor.
const swapThrough =
  (families: SwapFamily[]): Play =>
  async (ctx) => {
    const faces = families
      .flatMap((f) => [f.sans, f.serif, f.display, f.mono])
      .filter((value): value is FaceKey => value in FACES)
      .map((key) => FACES[key].family);
    await Promise.all(faces.map((family) => ctx.document.fonts.load(`400 15px "${family}"`)));
    await ctx.waitFor(() => ctx.document.fonts.status === "loaded");
    for (let i = 1; i < families.length; i += 1) {
      await ctx.click({ role: "button", name: "Swap family" });
      await ctx.waitFor(
        () => ctx.document.querySelector('[data-testid="family-swap-now"]')?.textContent === families[i].label,
      );
    }
  };

const variant = (note: string, props: FamilySwapProps) => ({ note, props, play: swapThrough(props.families) });

export default componentEntry<FamilySwapProps>({
  id: "font-study.family-swap",
  title: "Family swap: Quillet, the cmux family and the system font on one line box",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 720, normal: 960, wide: 1200 },
  covers: ["gallery/fontStudy/FamilySwap.tsx#FamilySwap"],
  keywords: ["font", "typeface", "quillet", "cmux sans", "cmux serif", "cmux mono", "line box", "swap"],
  anchors: ROWS.map((row) => ({ selector: `[data-swap-row="${row}"]` })),
  load: async () => (await import("./FamilySwap")).FamilySwap,
  variants: {
    "quillet-to-cmux": variant(
      "Quillet, then the cmux family, then Quillet, at 15 px with line-height normal: every row keeps its place.",
      { families: [QUILLET, CMUX, QUILLET] },
    ),
    "quillet-to-cmux-13": variant("The same at 13 px.", { families: [QUILLET, CMUX, QUILLET], size: 13 }),
    "quillet-to-cmux-17": variant("The same at 17 px.", { families: [QUILLET, CMUX, QUILLET], size: 17 }),
    "chat-line-height": variant("Quillet, then the cmux family, at the chat's 15 px on 1.4.", {
      families: [QUILLET, CMUX],
      lineHeight: 1.4,
    }),
    "system-chat-line-height": variant(
      "The system font, Quillet and the cmux family at the chat's 15 px on 1.4: a set line height holds every row.",
      { families: [SYSTEM, QUILLET, CMUX], lineHeight: 1.4 },
    ),
  },
});
