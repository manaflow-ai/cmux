import { useT } from "./i18n";

import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../ui/Menu";
import { type SpeedTiers } from "./fastToggleModel";
import { tooltipProps } from "./shortcuts";
/// The bolt: a plain outline glyph in muted ink while off, in the theme accent while a tier runs. No
/// disc, no fill at rest; hover draws the row's soft pill (composerLocation.css `.acpmux-fast`). A
/// click steps to the next offered tier, and from the last one back to off; with one tier it is
/// on/off.
export function FastToggle({ speed, inline = false }: { speed: SpeedTiers; inline?: boolean }) {
  const t = useT();
  if (speed.tiers.length === 0) return null;
  const at = speed.tiers.indexOf(speed.current ?? "");
  const nextAt = at + 1 < speed.tiers.length ? at + 1 : -1;
  const name = (index: number) => {
    const value = speed.tiers[index] ?? "";
    if (index < 0) return t("picker.tierStandard");
    if (/^(priority|fast|on|true|enabled)$/i.test(value)) return t("picker.tierFast");
    if (/^ultra[-_ ]?fast$/i.test(value)) return t("picker.tierUltrafast");
    return speed.names?.[value] ?? value;
  };
  const label = t("composer.speedLabel", { tier: name(at) });
  return (
    <span className="acpmux-speed">
      {inline ? (
        <button
          type="button"
          className="acpmux-fast"
          data-tier={at < 0 ? "off" : at === 0 ? "fast" : "ultrafast"}
          aria-pressed={at >= 0}
          aria-label={label}
          {...tooltipProps(t("composer.speedTooltip", { tier: name(at), next: name(nextAt) }), undefined)}
          // The inline glyph lives inside the model picker trigger. Stop the pointer gesture
          // before the parent trigger sees it, so choosing Fast does not also open the picker.
          onPointerDown={(event) => {
            event.preventDefault();
            event.stopPropagation();
          }}
          onClick={(event) => {
            event.stopPropagation();
            speed.onPick(nextAt < 0 ? speed.off : speed.tiers[nextAt]!);
          }}
          onKeyDown={(event) => {
            if (event.key !== "Enter" && event.key !== " ") return;
            event.preventDefault();
            event.stopPropagation();
            speed.onPick(nextAt < 0 ? speed.off : speed.tiers[nextAt]!);
          }}
        >
          <BoltIcon />
        </button>
      ) : (
        <button
          type="button"
          className="acpmux-fast"
          data-tier={at < 0 ? "off" : at === 0 ? "fast" : "ultrafast"}
          aria-pressed={at >= 0}
          aria-label={label}
          {...tooltipProps(t("composer.speedTooltip", { tier: name(at), next: name(nextAt) }), undefined)}
          // Keep focus and the caret in the prompt, as the mic does; Tab still reaches it.
          onMouseDown={(event) => event.preventDefault()}
          onClick={() => speed.onPick(nextAt < 0 ? speed.off : speed.tiers[nextAt]!)}
        >
          <BoltIcon />
          <span>{name(at < 0 ? 0 : at)}</span>
        </button>
      )}
      {!inline && (
        <Menu>
          <MenuButton className="acpmux-speed-choices" label={label} data-menu="Speed">
            ⌄
          </MenuButton>
          <MenuPopup className="acpmux-menu" label={label}>
            <MenuRadioGroup value={speed.current ?? speed.off} onValueChange={speed.onPick}>
              {[speed.off, ...speed.tiers].map((value, index) => (
                <MenuRadioItem key={value} value={value} closeOnClick>
                  {name(index - 1)}
                </MenuRadioItem>
              ))}
            </MenuRadioGroup>
          </MenuPopup>
        </Menu>
      )}
    </span>
  );
}

function BoltIcon() {
  return (
    <svg
      className="acpmux-icon"
      width={16}
      height={16}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M9.2 1.5 3.6 9h4.1l-1 5.5L12.4 7H8.3Z" />
    </svg>
  );
}
