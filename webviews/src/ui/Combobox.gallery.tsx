// l10n-allow-file: gallery fixture labels and sample choices are public-safe test content.
import { useMemo, useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Combobox } from "./Combobox";

type Props = {
  empty?: boolean;
  inline?: boolean;
  autoHighlight?: boolean | "always";
  disabled?: string;
};

const CHOICES = ["Alpha project", "Beta project", "Gamma project", "Delta project"];

function GalleryCombobox({ empty = false, inline = false, autoHighlight = false, disabled }: Props) {
  const [query, setQuery] = useState("");
  const [submitted, setSubmitted] = useState("");
  const [cancelled, setCancelled] = useState(0);
  const [highlighted, setHighlighted] = useState<string | undefined>();
  const suggestions = useMemo(() => {
    const needle = query.trim().toLowerCase();
    const choices = empty ? [] : CHOICES;
    return needle ? choices.filter((choice) => choice.toLowerCase().includes(needle)) : choices;
  }, [empty, query]);
  return (
    <div className="combobox-gallery" data-inline={inline ? "true" : "false"}>
      <Combobox
        label="Choose project"
        placeholder="Search projects"
        suggestions={suggestions}
        onQuery={setQuery}
        onSubmit={setSubmitted}
        onCancel={() => {
          setCancelled((count) => count + 1);
          setHighlighted(undefined);
        }}
        autoHighlight={autoHighlight}
        inline={inline}
        isItemDisabled={disabled ? (choice) => choice === disabled : undefined}
        onHighlight={setHighlighted}
        inputClassName="combobox-gallery-input"
        listClassName="combobox-gallery-list"
        itemClassName="combobox-gallery-item"
      />
      <output className="combobox-gallery-receipt" data-testid="combobox-gallery-receipt" aria-live="polite">
        {submitted ? `submitted: ${submitted}` : cancelled ? `cancelled: ${cancelled}` : "ready"}
        {highlighted ? ` · highlighted: ${highlighted}` : ""}
      </output>
    </div>
  );
}

const openSuggestions: Play = async (ctx) => {
  await ctx.focus({ role: "combobox", name: "Choose project" });
  await ctx.waitFor(() => ctx.find({ role: "option", name: "Alpha project" }));
};

const keyboardSubmit: Play = async (ctx) => {
  await ctx.focus({ role: "combobox", name: "Choose project" });
  await ctx.type("ga");
  await ctx.press("ArrowDown");
  await ctx.press("Enter");
  await ctx.waitFor(() =>
    ctx.document
      .querySelector('[data-testid="combobox-gallery-receipt"]')
      ?.textContent?.includes("submitted: Gamma project"),
  );
};

const tabCompletion: Play = async (ctx) => {
  await ctx.focus({ role: "combobox", name: "Choose project" });
  await ctx.type("a");
  await ctx.press("Tab");
  await ctx.waitFor(
    () => ctx.find({ role: "combobox", name: "Choose project" }).getAttribute("value") === "Alpha project",
  );
};

const escapeCancel: Play = async (ctx) => {
  await ctx.focus({ role: "combobox", name: "Choose project" });
  await ctx.type("beta");
  await ctx.press("Escape");
  await ctx.waitFor(() =>
    ctx.document.querySelector('[data-testid="combobox-gallery-receipt"]')?.textContent?.includes("cancelled: 1"),
  );
};

const disabledSkip: Play = async (ctx) => {
  await ctx.focus({ role: "combobox", name: "Choose project" });
  await ctx.waitFor(() => ctx.find({ role: "option", name: "Beta project" }).getAttribute("aria-disabled") === "true");
  await ctx.press("ArrowDown");
  await ctx.waitFor(
    () => ctx.find({ role: "combobox", name: "Choose project" }).getAttribute("aria-activedescendant") !== null,
  );
  await ctx.press("Enter");
  await ctx.waitFor(() =>
    ctx.document
      .querySelector('[data-testid="combobox-gallery-receipt"]')
      ?.textContent?.includes("submitted: Gamma project"),
  );
};

export default componentEntry<Props>({
  id: "ui.combobox",
  title: "Combobox",
  area: "Shared UI",
  height: 320,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: ".combobox-gallery-input" }],
  styles: () => Promise.all([import("./ui.css"), import("./popupSurface.css"), import("./Combobox.gallery.css")]),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Suggestions must open below the field without moving the input anchor.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "Portaled suggestions must not add document flow around the field.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Filtering and keyboard selection should stay within two display frames.",
    },
    settleMaxMs: {
      value: 250,
      reason: "The combobox is local state and should settle within a quarter second.",
    },
    popupLayer: {
      value: true,
      reason: "The suggestion list must remain visible above surrounding content without clipping.",
    },
  },
  covers: ["ui/Combobox.tsx#Combobox"],
  load: async () => GalleryCombobox,
  variants: {
    closed: { props: { empty: true } },
    open: { props: {}, play: openSuggestions },
    keyboard: { props: { autoHighlight: true }, play: keyboardSubmit },
    "tab-completion": { props: {}, play: tabCompletion },
    escape: { props: {}, play: escapeCancel },
    disabled: { props: { autoHighlight: "always", disabled: "Beta project" }, play: disabledSkip },
    inline: {
      props: { inline: true, autoHighlight: "always" },
      checks: {
        layoutShiftMax: {
          value: 0.25,
          reason: "Inline suggestions intentionally join document flow; the input anchor itself must remain stable.",
        },
      },
      play: openSuggestions,
    },
  },
});
