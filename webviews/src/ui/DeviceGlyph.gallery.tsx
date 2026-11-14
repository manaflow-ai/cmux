// l10n-allow-file: gallery fixtures (sample machine names), not shipped UI.
// Device glyphs (Leo 2026-11-14: "nicer icons ... across all the remote related areas"): every
// device kind beside its name, as a menu row lists machines and as the composer's chip shows one,
// in the shipped look and the candidates it was picked over. Light and dark are the theme axis.
import { createElement } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { DEVICE_GLYPH_VIEWBOX } from "./deviceGlyphPaths";
import type { DeviceKind } from "./deviceKinds";

type Look = "regular" | "medium" | "light" | "large";
type Props = { look: Look; offline?: boolean; boxes?: boolean };

const NAMES: Record<DeviceKind, string> = {
  macbook: "This Mac",
  "mac-mini": "build-mini",
  imac: "studio-imac",
  "mac-studio": "render-studio",
  "mac-pro": "tower-pro",
  "linux-desktop": "workstation",
  "linux-server": "gpu-box",
  cloud: "Cloud machine",
  iphone: "Phone",
  ipad: "Tablet",
  generic: "unknown-host",
};

const everyKindHasAGlyph: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelectorAll(".device-glyph-gallery-row").length > 0);
  for (const row of ctx.document.querySelectorAll(".device-glyph-gallery-row svg")) {
    if (!row.querySelector("path")) throw new Error(`${row.getAttribute("data-device")} drew no glyph`);
  }
};

const variant = (look: Look, note: string, extra: Partial<Props> = {}) => ({
  note,
  props: { look, ...extra },
  play: everyKindHasAGlyph,
});

export default componentEntry<Props>({
  id: "ui.device-glyph",
  title: "Device glyphs",
  area: "UI primitives",
  height: 460,
  styles: () => import("./DeviceGlyph.gallery.css"),
  covers: ["ui/DeviceGlyph.tsx#DeviceGlyph", "ui/DeviceGlyph.tsx#DeviceGlyphShapes"],
  load: () =>
    Promise.all([import("./DeviceGlyph"), import("./deviceGlyphVariants"), import("./deviceKinds")]).then(
      ([glyph, variants, kinds]) =>
        (props: Props) =>
          createElement(
            "div",
            { className: `device-glyph-gallery${props.boxes ? " device-glyph-gallery-boxes" : ""}` },
            ...kinds.DEVICE_KINDS.flatMap((kind) => {
              const paths = variants.DEVICE_GLYPH_VARIANTS[props.look];
              const shapes =
                props.look === "regular"
                  ? createElement(glyph.DeviceGlyphShapes, { kind })
                  : createElement(
                      "g",
                      null,
                      ...(paths[kinds.DEVICE_SYMBOLS[kind]] ?? []).map((layer, i) =>
                        createElement("path", {
                          key: i,
                          d: layer.d,
                          fill: "currentColor",
                          fillRule: layer.rule ?? "nonzero",
                        }),
                      ),
                    );
              const svg = (className: string, width: number) =>
                createElement(
                  "svg",
                  {
                    className: `ui-device-glyph ${className}`,
                    "data-device": kind,
                    "data-offline": props.offline ? "" : undefined,
                    width,
                    height: 14,
                    viewBox: DEVICE_GLYPH_VIEWBOX,
                    "aria-hidden": true,
                  },
                  shapes,
                );
              const row = (className: string, width: number) =>
                createElement(
                  "div",
                  {
                    key: `${kind}-${className}`,
                    className: "device-glyph-gallery-row",
                    "data-offline": props.offline ? "" : undefined,
                  },
                  svg(className, width),
                  createElement("span", null, NAMES[kind]),
                );
              // A menu row's square icon column, then the composer chip's wider slot.
              return [row("menu", 14), row("chip", 17.5)];
            }),
          ),
    ),
  variants: {
    regular: variant("regular", "Shipped: SF Symbols regular, the composer MacBook's scale"),
    medium: variant("medium", "Candidate: medium weight"),
    light: variant("light", "Candidate: light weight"),
    large: variant("large", "Candidate: 12% larger than the MacBook's scale"),
    offline: variant("regular", "Offline: the glyph dims with its label", { offline: true }),
    centering: variant("regular", "Glyph boxes: one box and one center line for every kind", { boxes: true }),
  },
});
