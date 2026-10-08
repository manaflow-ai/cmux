import type { ReactNode } from "react";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "./Menu";
import { cx } from "./cx";

/** One option in a shared macOS-style select. */
export interface SelectOption {
  value: string;
  label: ReactNode;
  disabled?: boolean;
  shortcut?: ReactNode;
}

/** Props for a select backed by the shared Menu primitive. */
export interface SelectProps {
  value: string;
  options: readonly SelectOption[];
  onChange(value: string): void;
  label: string;
  labelledBy?: string;
  disabled?: boolean;
  placeholder?: ReactNode;
  className?: string;
  buttonClassName?: string;
  popupClassName?: string;
}

/** A single-choice menu with native keyboard, VoiceOver and press-drag-release behavior. */
export function Select({
  value,
  options,
  onChange,
  label,
  labelledBy,
  disabled = false,
  placeholder = "",
  className,
  buttonClassName,
  popupClassName,
}: SelectProps) {
  const selected = options.find((option) => option.value === value);
  return (
    <span className={cx("ui-select", className)}>
      <Menu>
        <MenuButton
          className={cx("ui-select-button", buttonClassName)}
          label={label}
          aria-labelledby={labelledBy}
          disabled={disabled}
          aria-haspopup="menu"
        >
          <span className="ui-select-value">{selected?.label ?? placeholder}</span>
          <span className="ui-select-chevron" aria-hidden="true" />
        </MenuButton>
        <MenuPopup className={cx("ui-select-popup", popupClassName)}>
          <MenuRadioGroup value={value} onValueChange={onChange}>
            {options.map((option) => (
              <MenuRadioItem
                key={option.value}
                value={option.value}
                disabled={option.disabled}
                shortcut={option.shortcut}
                className="ui-select-option"
              >
                {option.label}
              </MenuRadioItem>
            ))}
          </MenuRadioGroup>
        </MenuPopup>
      </Menu>
    </span>
  );
}
