// appearance.accent as a swatch popup in the theme picker's style: the button shows the chosen
// accent's swatch and name at the theme pickers' one width, and the list shows every choice with the
// color it gives the current app theme, the checkmark on the right like the theme list's.
import { useEffect, useState } from "react";
import { Listbox } from "../../../ui/Listbox";
import { Popover } from "../../../ui/Popover";
import { Icon } from "../icons";

export type AccentChoice = {
  value: string;
  label: string;
  /** The accent color this choice gives the app theme; null while the theme's colors load. */
  swatch: string | null;
  /** Art Color: the hue comes from the art a window shows, drawn as a hue wheel. */
  art: boolean;
};

function Swatch({ choice }: { choice: AccentChoice }) {
  return (
    <span
      className="accent-swatch"
      data-accent-swatch={choice.value}
      data-accent-art={choice.art ? "" : undefined}
      style={!choice.art && choice.swatch ? { background: choice.swatch } : undefined}
    />
  );
}

export function AccentPicker({
  value,
  choices,
  labelId,
  label,
  disabled,
  onPick,
}: {
  value: string;
  choices: readonly AccentChoice[];
  labelId: string;
  /** The popover's accessible name (the row's title). */
  label: string;
  disabled: boolean;
  onPick(value: string): void | Promise<unknown>;
}) {
  const [open, setOpen] = useState(false);
  const [anchor, setAnchor] = useState<HTMLButtonElement | null>(null);
  const chosen = choices.find((choice) => choice.value === value) ?? choices[0];
  // Disabled while open (the key became managed, the host disconnected) closes it too.
  useEffect(() => {
    if (disabled && open) setOpen(false);
  }, [disabled, open]);
  return (
    <>
      <button
        ref={setAnchor}
        type="button"
        className="button theme-button"
        data-accent-picker=""
        aria-labelledby={labelId}
        aria-haspopup="listbox"
        aria-expanded={open}
        disabled={disabled}
        onClick={() => setOpen(!open)}
      >
        {chosen && <Swatch choice={chosen} />}
        <span className="theme-button-name">{chosen?.label ?? value}</span>
        <Icon name="chevron" />
      </button>
      <Popover
        open={open && !disabled}
        onOpenChange={setOpen}
        anchor={anchor}
        label={label}
        className="theme-popover accent-popover"
      >
        <Listbox
          items={choices}
          getKey={(choice) => choice.value}
          textValue={(choice) => choice.label}
          label={label}
          className="theme-list"
          rowClassName="theme-option"
          initialIndex={choices.findIndex((choice) => choice.value === value)}
          itemAttributes={(choice) => ({ "data-accent-option": choice.value })}
          onOpen={(choice) => {
            setOpen(false);
            if (choice.value !== value) void onPick(choice.value);
          }}
          renderItem={(choice) => (
            <span className="theme-option-row">
              <Swatch choice={choice} />
              <span className="theme-option-name">{choice.label}</span>
              {choice.value === value && <Icon name="check" className="theme-option-check" />}
            </span>
          )}
        />
      </Popover>
    </>
  );
}
