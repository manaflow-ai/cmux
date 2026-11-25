import type { CloudEnvironmentRow } from "../ops";
import { STATUS } from "../components/CloudEnvironmentsCard";

/** Settings > Cloud > Default Image's value that sends no environment (the chat page's AUTO_ENVIRONMENT). */
export const DEFAULT_IMAGE_AUTO = "auto";

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

/** The picked environment's build status as the Cloud Environments card words it; none for Auto or an
 * environment the list does not hold. A stale one is being rebuilt by the host (CloudEnvironmentsSettings.swift:
 * the Default Image rebuilds by itself when the agents a Cloud machine carries change, cmux#51731). */
export function defaultImageStatus(
  selected: string,
  environments: readonly Pick<CloudEnvironmentRow, "id" | "status">[],
): string | undefined {
  if (selected === DEFAULT_IMAGE_AUTO) return undefined;
  const status = environments.find((environment) => environment.id === selected)?.status;
  return status ? STATUS[status] : undefined;
}
