import { useEffect, useState } from "react";
import { useStore } from "../context";
import { STATUS } from "../components/CloudEnvironmentsCard";
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

/** `cloud.defaultImage`: a menu of Auto and the account's Cloud environments (`cmux.settings.environments.*`,
 * as the Cloud Environments card lists them), the current value selected, and its build status. Auto resets the key.
 * Each read (here on open and on a pick) lets the host rebuild a stale Default Image. */
/** How long the menu waits before each read again when one failed or the list was not available yet (signed in a
 * moment ago, the host still reading): the hq start-matrix-gui probe (run 46109146613) opened Settings right after
 * sign-in and the menu kept only Auto for good, while the account had its environment. Mutable for tests. */
export const defaultImageRetry = { delaysMs: [1_000, 2_000, 4_000, 8_000, 15_000] };

/** `cloud.defaultImage`: a menu of Auto and the account's Cloud environments (`cmux.settings.environments.*`,
 * as the Cloud Environments card lists them), the current value selected, and its build status. Auto resets the key.
 * Each read (here on open, on a pick, on window focus, and again after a failed one) lets the host rebuild a stale
 * Default Image. */
export function DefaultImageEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const [environments, setEnvironments] = useState<CloudEnvironmentRow[]>([]);
  useEffect(() => {
    let live = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let tries = 0;
    // A failed or not-yet-available read keeps the last list (Auto and the current value at first) and reads again
    // a few times; the Cloud Environments card says why. A host with no list (unsupported) is not asked again.
    const read = () => {
      clearTimeout(timer);
      void store
        .runEnvironments({ action: "refresh" })
        .then(({ state, failed, unsupported }) => {
          if (!live) return;
          if (state?.available) setEnvironments(state.environments);
          const delay = defaultImageRetry.delaysMs[tries];
          if (!unsupported && (failed || !state?.available) && delay !== undefined) {
            tries += 1;
            timer = setTimeout(read, delay);
          }
        })
        .catch(() => undefined);
    };
    read();
    const onFocus = () => {
      tries = 0;
      read();
    };
    window.addEventListener("focus", onFocus);
    return () => {
      live = false;
      clearTimeout(timer);
      window.removeEventListener("focus", onFocus);
    };
  }, [store, value]);
  const { selected, options } = defaultImageOptions(value, environments, t("settingsPage.cloud.defaultImageAuto"));
  const status = defaultImageStatus(selected, environments);
  return (
    <span className="inline-flex items-center gap-2">
      {status && (
        <span className="text-detail text-dim" data-default-image-status="">
          {t(status)}
        </span>
      )}
      <Select
        value={selected}
        disabled={disabled}
        labelId={labelId}
        onChange={(next) =>
          void (next === DEFAULT_IMAGE_AUTO ? store.reset(row.key) : store.set(row.key, next)).catch(() => undefined)
        }
      >
        {options.map((option) => (
          <option key={option.value} value={option.value} data-default-image={option.value}>
            {option.label}
          </option>
        ))}
      </Select>
    </span>
  );
}
