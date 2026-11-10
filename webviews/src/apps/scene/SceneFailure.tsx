import { useState } from "react";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import { copyTextResult } from "../../agent-session/acpmux/conversation/clipboard";
import { useT, type Translate } from "../../agent-session/acpmux/i18n";
import type { SceneStatus } from "./store";

/** What a failed mount says, in plain words: the native `AppFailureCopy`. The title says what
 * happened; `location` says where and why for a script error (`main.js · Line 2, column 12:
 * expecting ';'`); `place` is that place alone as the host wrote it (`main.js:2:12`), for the
 * one-line reload marker; `detail` is the host's raw reason, whole, for Details and Copy Error. */
export type SceneFailureCopy = { title: string; location?: string; place?: string; detail: string };

const PHASE = /^(?:init|main|runtime|mount|render):\s*/;
const NAMED = /^(?:[A-Z][A-Za-z]*)?(?:Error|Exception):\s*/;
const AT = /\s*\(?\s*\bat\s+(?:(?:<[^>]*>|[\w$.]+)\s+)?\(?([\w./-]+\.(?:js|mjs|cjs)|eval_script):(\d+):(\d+)\)?/;

/** Fills the catalog's positional `%1$@` placeholders (the strings are the Swift table's). */
function format(text: string, values: readonly string[]): string {
  return text.replace(/%(\d+)\$@/g, (whole, index: string) => values[Number(index) - 1] ?? whole);
}

export function sceneFailureCopy(reason: string, t: Translate): SceneFailureCopy {
  let text = reason.trim();
  for (let match = PHASE.exec(text); match; match = PHASE.exec(text)) text = text.slice(match[0].length);
  const named = NAMED.exec(text);
  const at = AT.exec(text);
  if (text.startsWith("app.limit:")) return { title: t("apps.failure.tooLarge"), detail: reason };
  if (at) {
    // The name and the place both take the spaces between them: clamp, never a reversed range.
    const start = Math.min(named ? named[0].length : 0, at.index);
    const message = text.slice(start, at.index).trim();
    const [, file, line = "", column = ""] = at;
    const location =
      file === "eval_script"
        ? message
          ? format(t("apps.failure.scriptAt"), [line, column, message])
          : format(t("apps.failure.scriptAtOnly"), [line, column])
        : message
          ? format(t("apps.failure.scriptInAt"), [file ?? "", line, column, message])
          : format(t("apps.failure.scriptInAtOnly"), [file ?? "", line, column]);
    return { title: t("apps.failure.script"), location, place: `${file}:${line}:${column}`, detail: reason };
  }
  if (named) return { title: t("apps.failure.script"), location: text.slice(named[0].length).trim(), detail: reason };
  return { title: t("apps.failure.generic"), detail: reason };
}

/** The quiet row a failed or disconnected mount draws in place of its scene (the native
 * `AppFailureNSView`). A failure shows its plain words, then Reload (when the host offers it), Copy
 * Error and Details; the raw reason shows only under Details. A disconnected mount's reason is
 * already plain words (the supervisor is unreachable): it draws as the one line, with no buttons.
 * Reload calls `onReload` synchronously from the click, as the host accepts it only from a gesture. */
export function SceneFailure({
  status,
  onReload,
  copyText = copyTextResult,
}: {
  status: Extract<SceneStatus, { state: "failed" | "disconnected" }>;
  onReload?: () => void;
  copyText?: (text: string) => unknown;
}) {
  const t = useT();
  // Keyed by the reason shown, so a new failure starts with Details closed and Copy Error unpressed.
  const [copiedFor, setCopiedFor] = useState<string>();
  const [openFor, setOpenFor] = useState<string>();
  if (status.state === "disconnected") {
    return (
      <div className="cmux-app-scene-failure" data-state="disconnected">
        <span className="cmux-app-scene-failure-title">{status.reason}</span>
      </div>
    );
  }
  const copy = sceneFailureCopy(status.reason, t);
  const open = openFor === status.reason;
  return (
    <div className="cmux-app-scene-failure" data-state="failed">
      <span className="cmux-app-scene-failure-title">{copy.title}</span>
      {copy.location ? <span className="cmux-app-scene-failure-location">{copy.location}</span> : null}
      <span className="cmux-app-scene-failure-actions">
        {onReload ? (
          <button
            type="button"
            className="cmux-app-scene-failure-action"
            data-action="reload"
            title={t("apps.mount.reload.help")}
            onClick={() => onReload()}
          >
            {t("apps.mount.reload")}
          </button>
        ) : null}
        <button
          type="button"
          className="cmux-app-scene-failure-action"
          data-action="copy"
          onClick={() => {
            copyText(copy.detail);
            setCopiedFor(status.reason);
          }}
        >
          {copiedFor === status.reason ? t("apps.failure.copied") : t("apps.failure.copy")}
        </button>
        <button
          type="button"
          className="cmux-app-scene-failure-action"
          data-action="details"
          aria-expanded={open}
          onClick={() => setOpenFor(open ? undefined : status.reason)}
        >
          {open ? t("apps.failure.hideDetails") : t("apps.failure.details")}
        </button>
      </span>
      {open ? <pre className="cmux-app-scene-failure-detail">{copy.detail}</pre> : null}
    </div>
  );
}

/** The line under a kept scene whose app's last save did not load (the native
 * `AppSceneReloadMarkerView`): a small warning glyph, "Not reloaded" and the `file:line` the error
 * names, in caption type. The scene above keeps drawing the script that last loaded; the whole
 * reason is the tooltip and the accessible label, so the line stays one row high whatever it says. */
export function SceneReloadMarker({ reason }: { reason: string }) {
  const t = useT();
  const copy = sceneFailureCopy(reason, t);
  const label = t("apps.mount.reloadFailed");
  const said = copy.location ?? copy.title;
  return (
    <div
      className="cmux-app-scene-reload-marker"
      title={said}
      aria-label={[label, copy.place, said].filter(Boolean).join(", ")}
    >
      <Icon name="status.warning" size={12} className="cmux-app-scene-reload-marker-glyph" />
      <span className="cmux-app-scene-reload-marker-label">{label}</span>
      {copy.place ? <span className="cmux-app-scene-reload-marker-place">{copy.place}</span> : null}
    </div>
  );
}
