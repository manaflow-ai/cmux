import { useEffect, useState } from "react";
import { useStore } from "../context";
import type { CloudEnvironmentRow } from "../ops";
import { t } from "../strings";
import { Select } from "./Select";
import type { EditorProps } from "./types";

/** Settings > Cloud > Default Image's value that sends no environment (the chat page's AUTO_ENVIRONMENT). */
export const DEFAULT_IMAGE_AUTO = "auto";
export const DEFAULT_IMAGE_KEY = "cloud.defaultImage";

export type DefaultImageOption = { value: string; label: string };

/** The menu's items: Auto, then the account's Cloud environments; a picked environment the list does
 * not hold (not read yet, or deleted) stays listed by its id, so the current value is always selected. */
export function defaultImageOptions(
  value: unknown,
  environments: readonly Pick<CloudEnvironmentRow, "id" | "name">[],
  autoLabel: string,
): { selected: string; options: DefaultImageOption[] } {
  const selected = typeof value === "string" && value !== "" ? value : DEFAULT_IMAGE_AUTO;
  const options: DefaultImageOption[] = [
    { value: DEFAULT_IMAGE_AUTO, label: autoLabel },
    ...environments.map((environment) => ({ value: environment.id, label: environment.name })),
  ];
  if (!options.some((option) => option.value === selected)) options.push({ value: selected, label: selected });
  return { selected, options };
}

/** `cloud.defaultImage`: a menu of Auto and the account's Cloud environments (`cmux.settings.environments.*`,
 * as the Cloud Environments card lists them), the current value selected. Auto resets the key. */
export function DefaultImageEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const [environments, setEnvironments] = useState<CloudEnvironmentRow[]>([]);
  useEffect(() => {
    let live = true;
    void store.runEnvironments({ action: "refresh" }).then(({ state }) => {
      if (live && state?.available) setEnvironments(state.environments);
    });
    return () => {
      live = false;
    };
  }, [store]);
  const { selected, options } = defaultImageOptions(value, environments, t("settingsPage.cloud.defaultImageAuto"));
  return (
    <Select
      value={selected}
      disabled={disabled}
      labelId={labelId}
      onChange={(next) => void (next === DEFAULT_IMAGE_AUTO ? store.reset(row.key) : store.set(row.key, next))}
    >
      {options.map((option) => (
        <option key={option.value} value={option.value} data-default-image={option.value}>
          {option.label}
        </option>
      ))}
    </Select>
  );
}
