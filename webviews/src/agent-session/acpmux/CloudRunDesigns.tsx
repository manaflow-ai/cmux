// l10n-allow-file: gallery design fixtures for where a new chat runs (Labs), not shipped UI.
// Three designs of the composer's This Mac or Cloud choice, side by side in the gallery. Only
// `row` ships (EnvironmentPicker's Cloud row); `bare` and `chip` exist here alone, around the real
// scope row, so the choice is made on what each looks like.
import { useState, type ComponentProps } from "react";
import { ComposerContext } from "./ComposerContext";
import { translate as t } from "./i18n";
import type { RunMode } from "./sandboxRun";

/// `row`: a Cloud row with a one-line subtitle at the top of the picker's Cloud section (shipped).
/// `bare`: the same row with no subtitle. `chip`: a This Mac / Cloud switch beside the picker.
export type CloudRunDesign = "row" | "bare" | "chip";

export type CloudRunDesignsProps = ComponentProps<typeof ComposerContext> & { design: CloudRunDesign; start?: RunMode };

export function CloudRunDesigns({ design, start = "persistent", ...props }: CloudRunDesignsProps) {
  const [mode, setMode] = useState<RunMode>(start);
  if (design !== "chip") {
    return (
      <>
        {design === "bare" && (
          <style>{'.acpmux-env-popover [data-mode="cloud"] .acpmux-env-detail { display: none; }'}</style>
        )}
        <ComposerContext {...props} runMode={{ mode, onMode: setMode }} />
      </>
    );
  }
  // The switch takes the choice out of the picker: the picker keeps its machines, with no Cloud row.
  const choice = (value: RunMode, label: string) => (
    <button
      type="button"
      className="acpmux-location-button ui-ghost ui-ghost-sm"
      aria-pressed={mode === value}
      data-press-active={mode === value ? "true" : undefined}
      onClick={() => setMode(value)}
    >
      {label}
    </button>
  );
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
      <fieldset
        aria-label="Where this chat runs"
        style={{ display: "inline-flex", gap: 2, border: 0, margin: 0, padding: 0 }}
      >
        {choice("persistent", t("composer.thisMac"))}
        {choice("cloud", t("composer.cloud"))}
      </fieldset>
      <ComposerContext {...props} />
    </div>
  );
}
