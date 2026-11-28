import { useEffect, useState } from "react";
import { useStore } from "../context";
import { STATUS } from "../components/cloudEnvironmentStatus";
import type { CloudEnvironmentRow } from "../ops";
import { t } from "../strings";
import { Select } from "./Select";
import { DEFAULT_IMAGE_AUTO, defaultImageOptions, defaultImageRetry, defaultImageStatus } from "./defaultImage";
import type { EditorProps } from "./types";

export const DEFAULT_IMAGE_KEY = "cloud.defaultImage";

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
