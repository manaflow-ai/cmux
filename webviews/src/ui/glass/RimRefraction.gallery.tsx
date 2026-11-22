// l10n-allow-file: gallery fixtures, not shipped UI.
// The rim of a floating glass bends the chat under it (rimRefraction.ts; Leo, 2026-11-07: "are we able
// to get the edge refraction like in ios? that's what ive been missing a lot of tbh like the little
// bumps and grooves and whatnot with more actual glass EFFECTS where it gets sometiems a little
// smooshed"). A model menu over a scrolled chat in a see-through Chromium page, over the app's own
// background art. The gallery runs no AppKit, so a stand-in draws the App's glass under the page: the
// art frosted under the menu's box (on macOS 26 the system's Liquid Glass also bends the art at its
// rim). The page's part is the real one: seeThroughBlur.ts blurs the chat in place under the menu and
// bends it across the rim's band at the variant's `--glass-refract`.
//
// Frame cost, from one harness (headless Chromium, software raster, 60 Hz, the chat scrolling under
// the open menu, CPU of every Chromium process per frame, median over 3 arts and the default): the
// filter before this change 7.1 ms (Great Wave, 3 runs); none 7.7; subtle 10.0; ios 10.1; strong 10.6.
// No variant dropped a frame. The cost is paid only while something moves under an open glass.
import { type CSSProperties, useEffect, useRef } from "react";
import hokusai from "../../gallery/fixtures/art/hokusai-great-wave.jpg?inline";
import sunrise from "../../gallery/fixtures/art/monet-impression-sunrise.jpg?inline";
import starryNight from "../../gallery/fixtures/art/van-gogh-starry-night.jpg?inline";
import { componentEntry } from "../../gallery/format";
import type { RefractionName } from "./rimRefraction";
import { useSeeThroughBlur } from "./seeThroughBlur";

type Art = "default" | "hokusai" | "sunrise" | "starry-night";
type Props = { refract: RefractionName; art: Art };

const ARTS: Record<Art, string | null> = { default: null, hokusai, sunrise, "starry-night": starryNight };
const BOX = { left: 300, top: 60, width: 260, radius: 14 };
const LINE =
  "I traced the stutter to the transcript's scroll handler: every wheel event read the composer's height, which forced a layout right after the virtualizer moved its rows. ";
const ITEMS = ["Opus 5.5", "Sonnet 5.5", "Haiku 5.5", "Effort: medium", "Thinking", "Fast mode"];

function RimRefractionGallery({ refract, art }: Props) {
  const menu = useRef<HTMLDivElement>(null);
  // The app's page is see-through: glass.css blurs in place only there.
  useEffect(() => {
    const root = document.documentElement;
    root.setAttribute("data-cmux-see-through", "");
    return () => root.removeAttribute("data-cmux-see-through");
  }, []);
  useSeeThroughBlur(menu, true, (surface) => [surface.previousElementSibling!].filter(Boolean));
  const image = ARTS[art];
  const backdrop = image ? `url("${image}") center / cover` : "rgb(28, 28, 31)";
  return (
    <div
      style={
        {
          position: "relative",
          height: 400,
          overflow: "hidden",
          background: backdrop,
          color: "rgb(236, 236, 240)",
          fontSize: "var(--text-body)",
          colorScheme: "dark",
          "--cmux-surface-background": "transparent",
          "--cmux-surface-solid": "rgb(30, 31, 36)",
        } as CSSProperties
      }
    >
      {/* The App's glass under the page, which sees the art and never the chat. */}
      <div
        aria-hidden="true"
        style={{
          position: "absolute",
          left: BOX.left,
          top: BOX.top,
          width: BOX.width,
          height: 232,
          borderRadius: BOX.radius,
          /* glass-raw-blur-allow: the gallery's stand-in for the App's native glass, not a page glass */
          backdropFilter: "blur(30px) saturate(1.6)",
          background: "color-mix(in srgb, var(--surface-popup) var(--ds-glass-lens-tint), transparent)",
        }}
      />
      <div style={{ position: "absolute", inset: 0, padding: "8px 24px", lineHeight: 1.5 }}>{LINE.repeat(14)}</div>
      <div
        ref={menu}
        className="ui-glass ui-glass-floats"
        style={
          {
            position: "absolute",
            left: BOX.left,
            top: BOX.top,
            width: BOX.width,
            height: 232,
            boxSizing: "border-box",
            padding: 6,
            borderRadius: BOX.radius,
            background: "transparent",
            backdropFilter: "none",
            "--glass-refract": refract,
          } as CSSProperties
        }
      >
        {ITEMS.map((item, index) => (
          <div
            key={item}
            style={{
              padding: "var(--ds-space-1) var(--ds-space-3)",
              borderRadius: 8,
              background: index === 1 ? "var(--ds-color-hover)" : undefined,
            }}
          >
            {item}
          </div>
        ))}
      </div>
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.glass-rim-refraction",
  title: "Glass rim refraction",
  area: "Pages",
  height: 420,
  covers: ["ui/glass/rimRefraction.ts#rimMap", "ui/glass/seeThroughBlur.ts#writeHoleFilter"],
  load: async () => RimRefractionGallery,
  variants: {
    before: {
      note: "Before: the chat under the menu is blurred evenly to the edge; nothing says the glass has a thickness. 7.7 ms CPU a frame while the chat scrolls under it.",
      props: { refract: "none", art: "hokusai" },
    },
    subtle: {
      note: "A 10 px rim pulls the chat in by up to 6 px, lightly blurred: a hint of an edge. 10.0 ms.",
      props: { refract: "subtle", art: "hokusai" },
    },
    ios: {
      note: "Ships: an 18 px rim pulls the chat in by up to 14 px and barely frosts it, so lines bend and squeeze into the edge as at the rim of the system's own popovers; the middle keeps its frost for the menu's text. 10.1 ms.",
      props: { refract: "ios", art: "hokusai" },
    },
    strong: {
      note: "A 26 px rim pulls in by up to 24 px: whole words squeeze into the edge, and at the top they crowd the first row. 10.6 ms.",
      props: { refract: "strong", art: "hokusai" },
    },
    "ios-sunrise": {
      note: "Ships, over Impression, Sunrise.",
      props: { refract: "ios", art: "sunrise" },
    },
    "ios-starry-night": {
      note: "Ships, over The Starry Night.",
      props: { refract: "ios", art: "starry-night" },
    },
    "ios-default": {
      note: "Ships, with no art (the default background).",
      props: { refract: "ios", art: "default" },
    },
  },
});
