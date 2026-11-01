import { createContext, type ReactNode, useContext, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Spinner } from "./conversation/icons";
import { useT } from "./i18n";
import { useNoticeTurn } from "./NoticeSlot";

/// One row of acpmux's `_acpmux/harness/health` (cx-ny85), as the host hands it to the pane
/// (`harness.health`).
export type HarnessHealth = {
  id: string;
  version?: string | null;
  latest?: string | null;
  outdated?: boolean;
  /// Only from evidence (a profile's check, or a probe's sign-in error); `expired`: a credential the
  /// check or probe said expired.
  auth?: "signedIn" | "signedOut" | "expired" | "unknown";
  /// The command that signs it in.
  login?: string | null;
  /// How to update it; `elevated`: it needs sudo, so the pane never offers it.
  update?: { command: string; elevated: boolean } | null;
};

/// Whether a health row's sign-in needs the person to log in: signed out, or its credential expired.
export const needsLogin = (auth: HarnessHealth["auth"]): boolean => auth === "signedOut" || auth === "expired";

/// The agent CLI versions the person chose to skip, by harness id (this browser profile).
const SKIPPED = "cmux.acpmux.skippedUpdates";

function skipped(): Record<string, string> {
  try {
    const value: unknown = JSON.parse(globalThis.localStorage?.getItem(SKIPPED) ?? "{}");
    return value && typeof value === "object" ? (value as Record<string, string>) : {};
  } catch {
    return {};
  }
}

function skip(id: string, version: string): void {
  try {
    globalThis.localStorage?.setItem(SKIPPED, JSON.stringify({ ...skipped(), [id]: version }));
  } catch {
    // No storage (a private window): skipped for this chat only.
  }
}

type Open = (params: { kind: "terminal"; text: string; cwd?: string; run: true }) => void;
/// The host's calls (`callNative`): `harness.update {id}` -> `{ok, version?, error?}` (it waits for
/// the real updater, which can take minutes) and `harness.restart {}` -> `{restarted, after_turn}`.
type Native = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// Where an update started from this card is (cx-1mbnu), for the card it was started from.
type Progress =
  | { key: string; phase: "updating" }
  | { key: string; phase: "updated"; version: string; restarting?: boolean; error?: string }
  | { key: string; phase: "waiting"; version: string }
  | { key: string; phase: "failed"; error: string };

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : {};
}

const message = (error: unknown) => (error instanceof Error ? error.message.trim() : "");

/// An agent CLI update on offer (hq#2569 #12): never a banner over the chat, and never a dot on the
/// model chip (Leo 2026-10-21). The chip's tooltip names it and its menu and picker offer Update and
/// Skip This Version (`UpdateOfferContext`).
export type UpdateOffer = {
  harness: string;
  agent: string;
  version: string;
  latest: string;
  update(): void;
  skip(): void;
};

export const UpdateOfferContext = createContext<UpdateOffer | undefined>(undefined);

export const useUpdateOffer = () => useContext(UpdateOfferContext);

/// Agent CLI health above the composer, one quiet line in the composer's notice slot: a
/// signed-out agent says so with Log In (an error: it outranks every other line), which runs its
/// login in a terminal tab of the chat's folder (`open`, the host's `tab.open`). An outdated one
/// draws nothing here: it hands `onOffer` its Update, which the model chip offers. Once the person
/// starts it, the host runs it in place (`harness.update`) while the line says so (the lowest
/// tier, so it never covers an error), then Restart Chat (`harness.restart`) to use the new
/// version. An update that needs sudo is left to Settings > Agents, which shows its command.
export function HarnessHealthNotice({
  health,
  harness,
  name,
  cwd,
  open,
  native,
  turnRunning = false,
  onUpdated,
  onOffer,
  onSignInVisible,
}: {
  health: HarnessHealth | undefined;
  /// The chat's agent now; a row for another (fetched before a switch) shows nothing.
  harness: string | undefined;
  name: string;
  cwd?: string;
  open: Open;
  native: Native;
  /// Whether the chat's turn is running: a restart the host holds for it happens when it ends.
  turnRunning?: boolean;
  /// The update is in use (or the restart is waiting on the turn): read the agent's health again.
  onUpdated?: () => void;
  /// The update on offer for the model chip, or undefined once there is none (or it started).
  onOffer?: (offer: UpdateOffer | undefined) => void;
  /// The sign-in card actually drawn, after dismissal and NoticeSlot arbitration.
  onSignInVisible?: (visible: boolean) => void;
}) {
  const t = useT();
  const [dismissed, setDismissed] = useState<string>();
  const [progress, setProgress] = useState<Progress>();
  const signedOut = health && needsLogin(health.auth) && health.login ? health.login : undefined;
  const update =
    health &&
    health.outdated &&
    health.version &&
    health.latest &&
    health.update &&
    !health.update.elevated &&
    skipped()[health.id] !== health.latest
      ? health.update.command
      : undefined;
  const kind = signedOut ? "signedOut" : update ? "outdated" : undefined;
  // Not Now holds for what it was said to (a newer version or a sign-out asks again).
  // An update started here holds its card (Restart Chat) even when health, read again, is current.
  const started = progress && health?.id === harness && progress.key.startsWith(`${harness}:outdated:`);
  const key = started ? progress.key : health && kind && `${health.id}:${kind}:${health.latest ?? ""}`;
  const state = started ? progress : undefined;
  const waiting = state?.phase === "waiting";
  // A restart held for the turn happened when it ended: the card is done.
  useEffect(() => {
    if (!waiting || turnRunning) return;
    setDismissed(key);
    setProgress(undefined);
    onUpdated?.();
  }, [waiting, turnRunning, key, onUpdated]);
  const ours = !!health && health.id === harness;
  // The offer (an outdated CLI nobody started updating) goes to the model chip, never this line.
  const offering = ours && kind === "outdated" && !state && key !== dismissed;
  const offerKey = offering ? key : undefined;
  const actions = useRef({ start: () => {}, skip: () => {} });
  const offerOut = useRef(onOffer);
  offerOut.current = onOffer;
  const offerId = health?.id;
  const offerVersion = health?.version ?? "";
  const offerLatest = health?.latest ?? "";
  useEffect(() => {
    if (!offerKey || !offerId) {
      offerOut.current?.(undefined);
      return;
    }
    offerOut.current?.({
      harness: offerId,
      agent: name,
      version: offerVersion,
      latest: offerLatest,
      update: () => actions.current.start(),
      skip: () => actions.current.skip(),
    });
  }, [offerKey, offerId, offerVersion, offerLatest, name]);
  useEffect(() => () => offerOut.current?.(undefined), []);
  const line = ours && !offering && !!(kind || state) && !!key && key !== dismissed;
  const turn = useNoticeTurn("harness-health", kind === "signedOut" ? "error" : "update", line);
  const signInVisible = ours && kind === "signedOut" && !offering && !!key && key !== dismissed && turn.shown;
  useLayoutEffect(() => {
    onSignInVisible?.(signInVisible);
  }, [onSignInVisible, signInVisible]);
  useLayoutEffect(() => () => onSignInVisible?.(false), [onSignInVisible]);
  if (!health || health.id !== harness) return null;
  if (!(kind || state) || !key || key === dismissed) return null;
  const run = (text: string) => open({ kind: "terminal", text, ...(cwd ? { cwd } : {}), run: true });
  const id = health.id;
  const latest = health.latest ?? "";
  const failed = (error: string) =>
    setProgress({ key, phase: "failed", error: error || t("harness.updateFailedGeneric") });
  const startUpdate = () => {
    setProgress({ key, phase: "updating" });
    native("harness.update", { id }).then(
      (value) => {
        const reply = record(value);
        if (reply.ok === true)
          setProgress({
            key,
            phase: "updated",
            version: typeof reply.version === "string" && reply.version ? reply.version : latest,
          });
        else failed(typeof reply.error === "string" ? reply.error.trim() : "");
      },
      (error: unknown) => failed(message(error)),
    );
  };
  const restart = (version: string) => {
    setProgress({ key, phase: "updated", version, restarting: true });
    native("harness.restart", {}).then(
      (value) => {
        const reply = record(value);
        const later = typeof reply.after_turn === "number" ? reply.after_turn : 0;
        if (typeof reply.failed === "number" && reply.failed > 0) {
          const error = typeof reply.error === "string" ? reply.error.trim() : "";
          setProgress({ key, phase: "updated", version, error: error || t("harness.restartFailedGeneric") });
          return;
        }
        if (later > 0) {
          setProgress({ key, phase: "waiting", version });
          return;
        }
        setDismissed(key);
        setProgress(undefined);
        onUpdated?.();
      },
      (error: unknown) =>
        setProgress({
          key,
          phase: "updated",
          version,
          error: message(error) || t("harness.restartFailedGeneric"),
        }),
    );
  };
  actions.current = {
    start: startUpdate,
    skip: () => {
      skip(id, latest);
      setDismissed(key);
    },
  };
  if (offering || !turn.shown) return null;
  const updating = state?.phase === "updating";
  const notNow = (
    <button type="button" data-notice-action="dismiss" disabled={updating} onClick={() => setDismissed(key)}>
      {t("harness.notNow")}
    </button>
  );
  let text: string;
  let buttons: ReactNode;
  if (kind === "signedOut") {
    text = health.auth === "expired" ? t("turn.authExpired") : t("harness.signedOut", { agent: name });
    buttons = (
      <button type="button" data-notice-action="login" onClick={() => run(signedOut!)}>
        {t("harness.logIn")}
      </button>
    );
  } else if (state?.phase === "updated") {
    text = state.error
      ? t("harness.restartFailed", { error: state.error })
      : t("harness.updated", { agent: name, version: state.version });
    buttons = (
      <button
        type="button"
        data-notice-action="restart"
        disabled={state.restarting === true}
        onClick={() => restart(state.version)}
      >
        {t("harness.restartChat")}
      </button>
    );
  } else if (state?.phase === "waiting") {
    text = t("harness.restartAfterTurn", { version: state.version });
    buttons = null;
  } else if (state?.phase === "failed") {
    text = t("harness.updateFailed", { agent: name, error: state.error });
    buttons = (
      <button type="button" data-notice-action="retry" onClick={startUpdate}>
        {t("harness.tryAgain")}
      </button>
    );
  } else {
    // Only an update the person started reaches here (the offer is the chip's).
    text = t("harness.updating", { agent: name });
    buttons = null;
  }
  const busy = state?.phase === "updating" || (state?.phase === "updated" && state.restarting === true);
  return (
    <output
      className="acpmux-host-error acpmux-harness-notice"
      data-harness-notice={kind ?? "outdated"}
      data-harness-phase={state?.phase}
      aria-busy={busy || undefined}
    >
      <div className="acpmux-host-error-card">
        {/* The spinner trails the text, so starting or finishing work never moves the words. */}
        <p className="acpmux-host-error-message">
          {text}
          {busy && <Spinner size={12} className="acpmux-harness-spinner" loading />}
        </p>
        {/* Not Now leads, so Restart Chat or Try Again appearing or going never moves it. */}
        <div className="acpmux-host-error-actions">
          {notNow}
          {buttons}
        </div>
      </div>
    </output>
  );
}
