// Settings > Agent Chat > Message Box: the dictation engine's key and connection check, drawn as rows
// under the dictation rows (agentPane.dictationSource and the three agentPane.dictationEngine* rows,
// which draw with the generic editors). Leo, 2026-11-22: "people should be able to add their own api
// keys/whatever ... to link up to their provider of choice ... the ui/ux and lifecycles for those
// should be really good".
// The engine's state comes from acpmux (`cmux.settings.dictation.run` `state`), read again when one of
// the engine's settings changes and when the page becomes visible. A key is pasted into a password
// field that lives only in the open form: it leaves the page's state before it is sent, the app moves
// it into the Keychain, and the page only ever learns whether one is saved. Check Connection asks
// acpmux for the cheapest call that proves the URL and key (no audio is sent); a Save that the app
// took runs it at once. The status line under the form keeps its height, so a result never moves
// the rows below it.
import { useEffect, useEffectEvent, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { userMessage } from "../../shared/userMessage";
import { useSettingsState, useStore } from "../context";
import { SETTINGS_SENTENCES, type DictationError, type DictationState } from "../ops";
import { valueOf } from "../store";
import { t } from "../strings";

export const DICTATION_SOURCE_KEY = "agentPane.dictationSource";
export const DICTATION_ENGINE_KEY = "agentPane.dictationEngine";
export const DICTATION_ENGINE_URL_KEY = "agentPane.dictationEngineURL";
export const DICTATION_ENGINE_MODEL_KEY = "agentPane.dictationEngineModel";

/** The dictation rows the card draws under, in their order on the card. */
const DICTATION_ROWS = [
  DICTATION_SOURCE_KEY,
  DICTATION_ENGINE_KEY,
  DICTATION_ENGINE_URL_KEY,
  DICTATION_ENGINE_MODEL_KEY,
];

/** The row the card draws under: the last dictation row among `rows` (a card's rows and its More
 * Options rows together), so the card follows the engine's rows wherever the page puts them. */
export function dictationCardAnchor(rows: readonly { key: string }[]): string | null {
  let anchor: string | null = null;
  let rank = -1;
  for (const row of rows) {
    const at = DICTATION_ROWS.indexOf(row.key);
    if (at > rank) {
      rank = at;
      anchor = row.key;
    }
  }
  return anchor;
}

/** What the status line under the card says. */
export type DictationStatus =
  | { kind: "idle" }
  | { kind: "checking" }
  | { kind: "connected" }
  | { kind: "failed"; error: DictationError }
  | { kind: "refused"; message: string };

/** `url`'s host (with its port), the part a person recognises; the URL as it is when it does not parse. */
export function dictationHost(url: string): string {
  try {
    return new URL(url).host || url;
  } catch {
    return url;
  }
}

/** A check's failure in plain words, each saying what to do. */
export function dictationErrorText(error: DictationError, state: DictationState): string {
  const host = dictationHost(state.url);
  switch (error.code) {
    case "key_missing":
      return t("settingsPage.dictationEngine.error.keyMissing");
    case "key_invalid":
      return t("settingsPage.dictationEngine.error.keyInvalid");
    case "offline":
      return t("settingsPage.dictationEngine.error.offline", host);
    case "timeout":
      return t("settingsPage.dictationEngine.error.timeout", host);
    case "rate_limited":
      return t("settingsPage.dictationEngine.error.rateLimited");
    case "bad_endpoint":
      return t("settingsPage.dictationEngine.error.badEndpoint");
    case "rejected":
      return error.detail.trim()
        ? t("settingsPage.dictationEngine.error.rejected", error.detail.trim())
        : t("settingsPage.dictationEngine.error.rejectedNoDetail");
    case "provider_error":
      return t("settingsPage.dictationEngine.error.providerError");
    case "bad_response":
      return t("settingsPage.dictationEngine.error.badResponse");
    case "not_configured":
      return t("settingsPage.dictationEngine.error.notConfigured");
    default:
      return t("settingsPage.dictationEngine.error.other");
  }
}

/** Which of the card's shapes `state` draws. */
export type DictationView = "onDevice" | "keyless" | "needsUrl" | "keyForm" | "keySaved";

export function dictationView(state: DictationState): DictationView {
  if (state.wire === "builtin" || state.engine === "onDevice") return "onDevice";
  if (state.key === "none") return "keyless";
  if (!state.keyAccount) return "needsUrl";
  return state.hasKey ? "keySaved" : "keyForm";
}

/** The card: reads acpmux's state for the engine the settings name, and sends the person's gestures. */
export function DictationProviderCard() {
  const store = useStore();
  const settings = useSettingsState();
  const source = valueOf(settings, DICTATION_SOURCE_KEY);
  const engine = valueOf(settings, DICTATION_ENGINE_KEY);
  const url = valueOf(settings, DICTATION_ENGINE_URL_KEY);
  const model = valueOf(settings, DICTATION_ENGINE_MODEL_KEY);
  const [read, setRead] = useState<{ kind: "loading" } | { kind: "failed" } | { kind: "ready"; state: DictationState }>(
    {
      kind: "loading",
    },
  );
  const [status, setStatus] = useState<DictationStatus>({ kind: "idle" });
  const [busy, setBusy] = useState(false);
  // Only the newest read or gesture writes: an engine change mid-check drops the older answer.
  const generation = useRef(0);
  // The newest gesture clears `busy`; a read on the page's return waits while one is out.
  const gestureId = useRef(0);
  const inFlight = useRef(false);
  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  const current = (mine: number) => alive.current && mine === generation.current;

  const load = async () => {
    const mine = ++generation.current;
    const reply = await store.runDictation({ action: "state" });
    if (!current(mine)) return;
    setRead(reply.ok ? { kind: "ready", state: reply.value } : { kind: "failed" });
  };

  // The engine's settings name what acpmux resolves: any change reads it again, and a result about
  // the old engine goes.
  const settingsKey = JSON.stringify([engine, url, model]);
  const reread = useEffectEvent(() => {
    setStatus({ kind: "idle" });
    setBusy(false);
    void load();
  });
  useEffect(() => {
    if (settingsKey) reread();
  }, [settingsKey]);

  // A key saved or removed elsewhere (another window, the CLI) shows when the page comes back.
  const refresh = useEffectEvent(() => {
    if (!inFlight.current) void load();
  });
  useEffect(() => {
    const visible = () => {
      if (document.visibilityState === "visible") refresh();
    };
    document.addEventListener("visibilitychange", visible);
    return () => document.removeEventListener("visibilitychange", visible);
  }, []);

  const check = async (mine: number) => {
    setStatus({ kind: "checking" });
    const reply = await store.runDictation({ action: "check" });
    if (!current(mine)) return;
    if (!reply.ok) setStatus({ kind: "refused", message: userMessage(reply.error, SETTINGS_SENTENCES) });
    else setStatus(reply.value.ok ? { kind: "connected" } : { kind: "failed", error: reply.value.error });
  };

  const gesture = async (work: (mine: number) => Promise<void>) => {
    const mine = ++generation.current;
    const id = ++gestureId.current;
    inFlight.current = true;
    setBusy(true);
    try {
      await work(mine);
    } finally {
      if (id === gestureId.current) {
        inFlight.current = false;
        if (alive.current) setBusy(false);
      }
    }
  };

  if (source !== undefined && source !== "cmux") return null;
  if (read.kind === "loading") return null;
  if (read.kind === "failed") return <DictationUnavailableRow onRetry={() => void load()} />;
  return (
    <DictationProviderRows
      state={read.state}
      status={status}
      busy={busy}
      onCheck={() => void gesture((mine) => check(mine))}
      onSave={async (key) => {
        let saved = false;
        await gesture(async (mine) => {
          setStatus({ kind: "idle" });
          const reply = await store.runDictation({ action: "setKey", key });
          if (!current(mine)) return;
          if (!reply.ok) {
            setStatus({ kind: "refused", message: userMessage(reply.error, SETTINGS_SENTENCES) });
            return;
          }
          saved = true;
          setRead({ kind: "ready", state: reply.value });
          await check(mine);
        });
        return saved;
      }}
      onRemove={() =>
        void gesture(async (mine) => {
          setStatus({ kind: "idle" });
          const reply = await store.runDictation({ action: "removeKey" });
          if (!current(mine)) return;
          if (reply.ok) setRead({ kind: "ready", state: reply.value });
          else setStatus({ kind: "refused", message: userMessage(reply.error, SETTINGS_SENTENCES) });
        })
      }
    />
  );
}

/** acpmux did not answer: a plain line and Try Again, never a blank card. */
export function DictationUnavailableRow({ onRetry }: { onRetry(): void }) {
  return (
    <div className="row" tabIndex={-1} data-dictation-provider="" data-dictation-view="unavailable">
      <div className="row-main">
        <div className="row-label">
          <div className="row-help">{t("settingsPage.dictationEngine.unavailable")}</div>
        </div>
        <div className="row-control">
          <Button type="button" className="button" data-dictation-action="retry" onClick={onRetry}>
            {t("settingsPage.dictationEngine.tryAgain")}
          </Button>
        </div>
      </div>
    </div>
  );
}

/** The card's rows for one state (the gallery draws each). */
export function DictationProviderRows({
  state,
  status,
  busy,
  onCheck,
  onSave,
  onRemove,
}: {
  state: DictationState;
  status: DictationStatus;
  busy: boolean;
  onCheck(): void;
  /** Sends the key; resolves once the app answered (and the check after it ran), true when it was saved. */
  onSave(key: string): Promise<boolean>;
  onRemove(): void;
}) {
  const view = dictationView(state);
  const [replacing, setReplacing] = useState(false);
  const [confirming, setConfirming] = useState(false);
  // A new engine, or a key saved or removed, closes Replace and Remove's question.
  const shape = `${state.engine}|${state.keyAccount ?? ""}|${String(state.hasKey)}`;
  const [seenShape, setSeenShape] = useState(shape);
  if (seenShape !== shape) {
    setSeenShape(shape);
    setReplacing(false);
    setConfirming(false);
  }
  const host = dictationHost(state.url);
  const help =
    view === "onDevice"
      ? t("settingsPage.dictationEngine.onDevice")
      : view === "keyless"
        ? t("settingsPage.dictationEngine.server", state.url)
        : view === "needsUrl"
          ? t("settingsPage.dictationEngine.needsUrl")
          : t("settingsPage.dictationEngine.cloud", host);
  const title =
    view === "keyForm" || view === "keySaved"
      ? state.key === "optional"
        ? t("settingsPage.dictationEngine.keyTitleOptional")
        : t("settingsPage.dictationEngine.keyTitle")
      : "";
  // A required key that is not saved yet has nothing to check: the form comes first.
  const checkable = view === "keyless" || view === "keySaved" || (view === "keyForm" && state.key === "optional");
  const form = view === "keyForm" || (view === "keySaved" && replacing);
  return (
    <div
      className="row accounts-row"
      tabIndex={-1}
      data-dictation-provider=""
      data-dictation-view={view}
      data-dictation-engine={state.engine}
      aria-busy={busy}
    >
      <div className="row-main">
        <div className="row-label">
          {title && <div className="row-title">{title}</div>}
          <div className="row-help" data-dictation-help="">
            {help}
          </div>
        </div>
        {checkable && (
          <div className="row-control">
            <Button type="button" className="button" data-dictation-action="check" disabled={busy} onClick={onCheck}>
              {t("settingsPage.dictationEngine.check")}
            </Button>
          </div>
        )}
      </div>
      {view !== "onDevice" && view !== "needsUrl" && (
        <div className="accounts-body accounts-team-body">
          {view === "keySaved" && !replacing && (
            <div className="accounts-buttons" data-dictation-saved="">
              <span className="accounts-status" data-status="success">
                <span className="accounts-dot" aria-hidden="true" />
                {t("settingsPage.dictationEngine.saved")}
              </span>
              {!confirming && (
                <>
                  <Button
                    type="button"
                    className="button"
                    data-dictation-action="replace"
                    disabled={busy}
                    onClick={() => setReplacing(true)}
                  >
                    {t("settingsPage.dictationEngine.replace")}
                  </Button>
                  <Button
                    danger
                    type="button"
                    className="button danger"
                    data-dictation-action="remove"
                    disabled={busy}
                    onClick={() => setConfirming(true)}
                  >
                    {t("settingsPage.remove")}
                  </Button>
                </>
              )}
            </div>
          )}
          {view === "keySaved" && confirming && (
            <div
              className="accounts-form"
              role="alertdialog"
              aria-label={t("settingsPage.dictationEngine.removeConfirm")}
            >
              <span className="row-help">{t("settingsPage.dictationEngine.removeConfirm")}</span>
              <div className="accounts-buttons">
                <Button
                  danger
                  type="button"
                  className="button danger"
                  data-dictation-action="confirmRemove"
                  disabled={busy}
                  onClick={() => {
                    setConfirming(false);
                    onRemove();
                  }}
                >
                  {t("settingsPage.remove")}
                </Button>
                <Button type="button" className="button" onClick={() => setConfirming(false)}>
                  {t("settingsPage.cancel")}
                </Button>
              </div>
            </div>
          )}
          {form && (
            <DictationKeyForm
              optional={state.key === "optional"}
              busy={busy}
              onSave={async (key) => {
                // A replaced key keeps the same shape, so Replace closes here once the app took it.
                if (await onSave(key)) setReplacing(false);
              }}
              onCancel={replacing ? () => setReplacing(false) : null}
            />
          )}
          {checkable || form ? <DictationStatusLine status={status} state={state} /> : null}
        </div>
      )}
    </div>
  );
}

/** The key field: a password field whose value lives only here and leaves before it is sent. */
function DictationKeyForm({
  optional,
  busy,
  onSave,
  onCancel,
}: {
  optional: boolean;
  busy: boolean;
  onSave(key: string): Promise<void>;
  onCancel: (() => void) | null;
}) {
  const [key, setKey] = useState("");
  const label = optional
    ? t("settingsPage.dictationEngine.keyTitleOptional")
    : t("settingsPage.dictationEngine.keyTitle");
  const send = () => {
    const value = key.trim();
    if (!value || busy) return;
    // The key leaves the page's state before it is sent; a refusal asks for it again.
    setKey("");
    void onSave(value);
  };
  return (
    <form
      className="accounts-form"
      data-dictation-key-form=""
      onSubmit={(event) => {
        event.preventDefault();
        send();
      }}
    >
      <Input
        className="field"
        type="password"
        name="dictation-key"
        aria-label={label}
        autoComplete="off"
        autoCorrect="off"
        autoCapitalize="off"
        spellCheck={false}
        data-1p-ignore=""
        data-lpignore="true"
        maxLength={4096}
        value={key}
        disabled={busy}
        onChange={(event) => setKey(event.target.value)}
      />
      <div className="accounts-buttons">
        <Button type="submit" className="button" data-dictation-action="save" disabled={busy || !key.trim()}>
          {t("settingsPage.dictationEngine.save")}
        </Button>
        {onCancel && (
          <Button
            type="button"
            className="button"
            data-dictation-action="cancel"
            onClick={() => {
              setKey("");
              onCancel();
            }}
          >
            {t("settingsPage.cancel")}
          </Button>
        )}
      </div>
    </form>
  );
}

/** The check's progress and result. The line is always there (a blank one at rest), so a result
 * appearing never moves what is under the card. */
function DictationStatusLine({ status, state }: { status: DictationStatus; state: DictationState }) {
  const tone =
    status.kind === "connected"
      ? "success"
      : status.kind === "failed" || status.kind === "refused"
        ? "attention"
        : "quiet";
  const words =
    status.kind === "checking"
      ? t("settingsPage.dictationEngine.checking")
      : status.kind === "connected"
        ? t("settingsPage.dictationEngine.connected")
        : status.kind === "failed"
          ? dictationErrorText(status.error, state)
          : status.kind === "refused"
            ? status.message
            : null;
  return (
    <output className="row-help block" data-dictation-status={status.kind}>
      {words ? (
        <span className="accounts-status" data-status={tone}>
          <span className="accounts-dot" aria-hidden="true" />
          <span data-dictation-status-text="">{words}</span>
        </span>
      ) : (
        <span aria-hidden="true">{"\u00a0"}</span>
      )}
    </output>
  );
}
