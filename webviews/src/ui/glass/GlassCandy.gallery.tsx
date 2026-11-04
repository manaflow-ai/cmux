// l10n-allow-file: gallery fixtures, not shipped UI.
// Glass candy (design/theming.md step 5; Leo 2026-11-04: "we don't have the candy yet"): the shared
// glass over the person's art in four looks, the arms of the glass-candy experiment, so the UI judge
// can rank them (`ui-climb run ui.glass-candy --exp glass-candy --arms plain,refraction,depth,art-tint`,
// with the plain-<art> variants as its states). Each `<look>-<art>` variant is also a direct link. The
// gallery's own URL keys apply as everywhere: theme, accent, colorScheme, density, scale,
// reducedMotion, and `background` (light, dark, busy) puts the window's own picture behind any variant.
import { componentEntry } from "../../gallery/format";
import type { Art, Candy, GlassCandyProps } from "../../gallery/fixtures/GlassCandyStage";
import { glassCandy } from "./glassCandy.experiment";

const ARTS: Record<Art, string> = {
  starry: "Van Gogh's Starry Night: deep blues and a swirl of yellow, the colorful dark case",
  wave: "Hokusai's Great Wave: a light paper sky over saturated blue",
  sunrise: "Monet's Impression, Sunrise: low-contrast haze with one hot orange",
  light: "the gallery's light picture (a pale photo-like gradient)",
  dark: "the gallery's dark picture",
  busy: "the gallery's busy picture: high-contrast stripes, the worst case for text",
};

const LOOKS: Record<Candy, string> = {
  plain: "The glass as it ships, over",
  refraction:
    "Refraction: the lens with a thick rim and full gloss, a loupe that bends and magnifies the art (it follows the pointer), and one sheen across each glass on entry and hover, over",
  depth:
    "Depth: three glass panes at three depths, rising elevation, leaning toward the pointer (near pane most), over",
  "art-tint":
    "Tint that follows the art: the glass mixed toward the art's leading color at the least alpha that keeps the text 4.5:1 over any part of it (the readout says the worst case), over",
};

const variants: Record<string, { note: string; props: GlassCandyProps }> = {};
for (const candy of Object.keys(LOOKS) as Candy[])
  for (const art of Object.keys(ARTS) as Art[])
    variants[`${candy}-${art}`] = { note: `${LOOKS[candy]} ${ARTS[art]}.`, props: { candy, art } };
variants["refraction-spectrum-starry"] = {
  note: "Refraction under Spectrum: the thick rim split per channel, over Starry Night.",
  props: { candy: "refraction", art: "starry", mode: "spectrum" },
};
variants["depth-lens-starry"] = {
  note: "Depth over the lens: each pane bends the art at its rim as it leans.",
  props: { candy: "depth", art: "starry", mode: "lens" },
};

export default componentEntry<GlassCandyProps>({
  id: "ui.glass-candy",
  title: "Glass candy",
  area: "Pages",
  height: 520,
  experimental: true,
  keywords: ["refraction", "lens", "depth", "parallax", "tint", "wallpaper", "art", "candy"],
  covers: ["gallery/fixtures/GlassCandyStage.tsx#GlassCandyStage", "gallery/theme/artTint.ts"],
  load: async () => (await import("../../gallery/fixtures/GlassCandyStage")).GlassCandyStage,
  styles: () => import("../../gallery/fixtures/glassCandy.gallery.css"),
  experiment: {
    definition: glassCandy,
    script: [
      {
        name: "the art read and the entry motion done",
        run: (ctx) => ctx.waitFor(() => ctx.document.querySelector(".candy-stage[data-settled]")),
      },
    ],
  },
  variants,
});
