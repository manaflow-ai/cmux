// l10n-allow-file: gallery fixture labels and sample choices are public-safe test content.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Select, type SelectOption } from "./Select";

type Props = {
  initial?: string;
  includeDisabled?: boolean;
  disabled?: boolean;
};

const OPTIONS: SelectOption[] = [
  { value: "comfortable", label: "Comfortable" },
  { value: "compact", label: "Compact", shortcut: "⌥C" },
  { value: "dense", label: "Dense" },
];

function GallerySelect({ initial = "comfortable", includeDisabled = false, disabled = false }: Props) {
  const [value, setValue] = useState(initial);
  const options = includeDisabled
    ? OPTIONS.map((option) => ({ ...option, disabled: option.value === "dense" }))
    : OPTIONS;
  return (
    <div className="select-gallery">
      <Select
        label="Choose density"
        value={value}
        options={options}
        disabled={disabled}
        onChange={setValue}
        className="select-gallery-control"
        buttonClassName="select-gallery-button"
      />
      <output className="select-gallery-receipt" data-testid="select-gallery-receipt" aria-live="polite">
        Density: {options.find((option) => option.value === value)?.label ?? "Unknown"}
      </output>
    </div>
  );
}

const open: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Choose density" });
  await ctx.waitFor(() => ctx.find({ role: "menuitemradio", name: "Comfortable" }));
};

const keyboard: Play = async (ctx) => {
  await ctx.focus({ role: "button", name: "Choose density" });
  await ctx.press("Enter");
  await ctx.press("ArrowDown");
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector(".select-gallery-receipt")?.textContent?.includes("Compact"));
};

const disabled: Play = async (ctx) => {
  await open(ctx);
  await ctx.waitFor(() => ctx.find({ role: "menuitemradio", name: "Dense" }).getAttribute("aria-disabled") === "true");
  // The shortcut is part of the item's name ("Compact⌥C").
  await ctx.click({ role: "menuitemradio", name: /^Compact/ });
  await ctx.waitFor(() => ctx.document.querySelector(".select-gallery-receipt")?.textContent?.includes("Compact"));
};

export default componentEntry<Props>({
  id: "ui.select",
  title: "Select",
  area: "Shared UI",
  height: 260,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: ".select-gallery-control" }],
  styles: () => Promise.all([import("./ui.css"), import("./popupSurface.css"), import("./Select.gallery.css")]),
  checks: {
    anchorMovePx: { value: 0, reason: "Opening a select must not move its trigger geometry." },
    layoutShiftMax: { value: 0, reason: "The portaled select menu must not add document flow around the control." },
    longFrameFailMs: {
      value: 33,
      reason: "Select keyboard and choice feedback should stay within two display frames.",
    },
    settleMaxMs: { value: 250, reason: "Select opening and choice updates are local interactions." },
    popupLayer: { value: true, reason: "The select menu must remain topmost and unclipped." },
  },
  covers: ["ui/Select.tsx#Select"],
  load: async () => GallerySelect,
  variants: {
    closed: { props: {} },
    open: { props: {}, play: open },
    keyboard: { props: {}, play: keyboard },
    disabled: { props: { includeDisabled: true }, play: disabled },
    "disabled-control": { props: { disabled: true } },
    compact: { props: { initial: "compact" } },
  },
});
