import { useT } from "./i18n";
import "./busyMacChip.css";

/// How the chip draws (BusyMacChip.gallery.tsx compares them): `chip`, a tonal pill with a gauge and
/// the whole sentence (shipped); `compact`, the gauge and the machine's name, the sentence in its
/// tooltip; `link`, the sentence as quiet text with no fill.
export type BusyMacChipLook = "chip" | "compact" | "link";

/// "This Mac is busy · Run on NAME" (design/remote-spin-up.md 2.3): one button at the end of a new
/// chat's strip while acpmux's placement says this Mac is over its budget and another machine has
/// room (placement.ts busyChoice). A click starts this chat there; nothing else changes, and the
/// next chat starts on This Mac again. `why` is placement's own verdict ("over its budget (load1
/// 29.8 >= 15)"), its tooltip. It sits in the strip's row at the strip's height, so it moves nothing
/// above or below it.
export function BusyMacChip({
  machine,
  why,
  onRun,
  look = "chip",
}: {
  machine: string;
  why: string;
  onRun(): void;
  look?: BusyMacChipLook;
}) {
  const t = useT();
  const text = t("composer.busyMac", { machine });
  return (
    <button
      type="button"
      className="acpmux-busy-mac"
      data-look={look}
      data-testid="busy-mac-chip"
      title={`${text}\n${why}`}
      aria-label={text}
      onClick={onRun}
    >
      <svg
        className="acpmux-busy-mac-icon"
        width={12}
        height={12}
        viewBox="0 0 16 16"
        fill="none"
        stroke="currentColor"
        strokeWidth={1.4}
        strokeLinecap="round"
        aria-hidden="true"
        focusable="false"
      >
        <path d="M2.5 11.5a5.5 5.5 0 1 1 11 0" />
        <path d="m8 11.5 3-4" />
      </svg>
      <span className="acpmux-busy-mac-text">{look === "compact" ? machine : text}</span>
    </button>
  );
}
