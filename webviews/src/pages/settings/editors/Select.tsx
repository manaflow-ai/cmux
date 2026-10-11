import { Children, isValidElement, type ReactNode } from "react";
import { Select as UiSelect, type SelectOption } from "../../../ui/Select";

/** A settings select backed by the shared macOS menu primitive. */
export function Select({
  value,
  disabled,
  labelId,
  onChange,
  children,
}: {
  value: string;
  disabled: boolean;
  labelId: string;
  onChange: (value: string) => void;
  children: ReactNode;
}) {
  const options: SelectOption[] = Children.toArray(children).flatMap((child) => {
    if (!isValidElement<{ value?: string; disabled?: boolean; children?: ReactNode }>(child) || child.type !== "option")
      return [];
    const option = child.props;
    const optionValue = String(option.value ?? "");
    return [{ value: optionValue, label: option.children, disabled: option.disabled }];
  });
  return (
    <span className="select">
      {/* Kept as a form-compatible mirror for settings automation and host integrations. The
          visible control is the shared Menu-backed Select beside it. */}
      <select
        className="field ui-select-native"
        value={value}
        disabled={disabled}
        aria-labelledby={labelId}
        aria-hidden="true"
        onChange={(event) => onChange(event.currentTarget.value)}
      >
        {children}
      </select>
      <UiSelect
        value={value}
        options={options}
        disabled={disabled}
        label=""
        labelledBy={labelId}
        onChange={onChange}
        className="ui-select-shared"
        buttonClassName="field"
      />
    </span>
  );
}
