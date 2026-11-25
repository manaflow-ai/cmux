import { useEffect, useState } from "react";
import { useStore } from "../context";
import type { CloudEnvironmentRow } from "../ops";
import { t } from "../strings";
import { Select } from "./Select";
import { DEFAULT_IMAGE_AUTO, defaultImageOptions, defaultImageStatus } from "./defaultImage";
import type { EditorProps } from "./types";

export const DEFAULT_IMAGE_KEY = "cloud.defaultImage";

/** `cloud.defaultImage`: a menu of Auto and the account's Cloud environments (`cmux.settings.environments.*`,
 * as the Cloud Environments card lists them), the current value selected, and its build status. Auto resets the key.
 * Each read (here on open and on a pick) lets the host rebuild a stale Default Image. */
export function DefaultImageEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const [environments, setEnvironments] = useState<CloudEnvironmentRow[]>([]);
  useEffect(() => {
    let live = true;
    // A failed read leaves the menu at Auto and the current value; the Cloud Environments card says why.
    void store
      .runEnvironments({ action: "refresh" })
      .then(({ state }) => {
        if (live && state?.available) setEnvironments(state.environments);
      })
      .catch(() => undefined);
    return () => {
      live = false;
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
