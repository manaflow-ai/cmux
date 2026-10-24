import { useEffect, useRef, useState } from "react";
import { failureKind } from "./failureCopy";
import { Spinner } from "./conversation/icons";
import { currentLanguage, useT } from "./i18n";
import { useNoticeTurn } from "./NoticeSlot";

/// Why the chat cannot reach its model (paid-plan.md section 4): its harness is signed out, a turn
/// was refused for its key or sign-in, or the cmux model router answered that credits ran out
/// (`credits.insufficient`) or that the account has none (`inference.plan_required`).
export type AccessNeed = "signedOut" | "key" | "credits";

/// The cmux model router's 402s (backend inference/route.ts): checked before capacity words, since
/// their `type` is `insufficient_quota`.
const CREDITS = /\bcredits\.insufficient\b|\binference\.plan_required\b|\badd_credits\b/;

/// The access a failed turn says is missing: `credits` for the router's 402s, `key` for a key or
/// sign-in refusal (failureCopy.ts kinds `invalid-key`, `subscription-login`, `auth`), else none.
export function missingAccess(message: string | undefined, code?: string): "key" | "credits" | undefined {
  if (!message) return undefined;
  if (CREDITS.test(message)) return "credits";
  const kind = failureKind(message, undefined, code);
  return kind === "invalid-key" || kind === "subscription-login" || kind === "auth" ? "key" : undefined;
}

/// The amounts a top-up offers, in USD, when the host names none (backend credits-checkout.ts).
const AMOUNTS = [10, 20, 50, 100] as const;

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

type Phase =
  | { phase: "idle" }
  | { phase: "working"; what: "addKey" | "useCredits" | "topup" }
  | { phase: "paying"; started: number }
  | { phase: "added"; seconds: number }
  | { phase: "failed"; error: string };

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : {};
}

const message = (error: unknown) => (error instanceof Error ? error.message.trim() : "");

/// The missing-access card above the composer, in the notice slot's error tier: one card for every
/// way a chat lacks access to its model. Its ways out:
/// - Log In (a signed-out harness with a login command): the harness's own sign-in.
/// - Add API key: the host's native sheet stores the key in the Mac's Keychain (the page never sees
///   it) and answers the acpmux route that sends it (`access.addKey`); the chat moves onto that route
///   (`onUseRoute`) and the turn goes again.
/// - Use cmux credits, where the cmux model router serves the chat's harness (`canUseCredits`: acpmux
///   lists the `cmux` route as serving it; Claude Code, OpenCode and Pi, never Codex or Gemini CLI):
///   `onUseCredits` moves the chat onto the router, and the turn goes again.
/// - Add credits, once the router says credits ran out: an amount opens Checkout (`credits.topup`,
///   in the cmux browser when it holds a Stripe Link sign-in), the host waits for the balance to rise
///   (`credits.wait`, which also asks the return page to grant the payment at once), then the
///   blocked turn goes again by itself. The card says how long from the click to usable credits.
export function MissingAccessNotice({
  need,
  harness,
  family,
  name,
  native,
  canUseCredits,
  onLogIn,
  onUseRoute,
  onUseCredits,
  onRetry,
  now = () => performance.now(),
}: {
  need: AccessNeed | undefined;
  /// The chat's acpmux harness id, and its family (what an API key route serves).
  harness: string | undefined;
  family: string | undefined;
  /// The harness's display name.
  name: string;
  native: Native;
  canUseCredits: boolean;
  /// Runs the signed-out harness's login; undefined when it names none.
  onLogIn?: () => void;
  /// Binds the chat to acpmux route `routeId`.
  onUseRoute: (routeId: string) => Promise<void>;
  /// Moves the chat onto the cmux model router.
  onUseCredits: () => Promise<void>;
  /// Sends the blocked turn again; undefined when there is none (a pick before the first prompt).
  onRetry?: () => void;
  /// The clock the click-to-usable time is read from (a test's own).
  now?: () => number;
}) {
  const t = useT();
  const [state, setState] = useState<Phase>({ phase: "idle" });
  const [dismissed, setDismissed] = useState<string>();
  const key = need && harness ? `${harness}:${need}` : undefined;
  // A new need (another harness, or credits after a key) starts the card over.
  const shownKey = useRef(key);
  useEffect(() => {
    if (shownKey.current === key) return;
    shownKey.current = key;
    setState((current) => (current.phase === "added" || current.phase === "paying" ? current : { phase: "idle" }));
  }, [key]);
  const wants = !!key && key !== dismissed;
  const turn = useNoticeTurn("missing-access", "error", wants || state.phase === "paying" || state.phase === "added");
  if (!turn.shown || !harness) return null;
  const busy = state.phase === "working" || state.phase === "paying";
  const fail = (error: unknown) => setState({ phase: "failed", error: message(error) || t("access.failedGeneric") });
  const addKey = () => {
    setState({ phase: "working", what: "addKey" });
    native("access.addKey", { harness, ...(family ? { family } : {}) })
      .then(async (value) => {
        const reply = record(value);
        if (reply.cancelled === true || typeof reply.routeId !== "string") {
          setState({ phase: "idle" });
          return;
        }
        await onUseRoute(reply.routeId);
        setState({ phase: "idle" });
        setDismissed(key);
        onRetry?.();
      })
      .catch(fail);
  };
  const useCredits = () => {
    setState({ phase: "working", what: "useCredits" });
    onUseCredits().then(() => {
      setState({ phase: "idle" });
      setDismissed(key);
      onRetry?.();
    }, fail);
  };
  const topUp = (usd: number) => {
    const started = now();
    setState({ phase: "working", what: "topup" });
    native("credits.topup", { usd })
      .then(async (value) => {
        const opened = record(value);
        const before = typeof opened.before_usd === "number" ? opened.before_usd : 0;
        const session = typeof opened.session === "string" ? opened.session : undefined;
        setState({ phase: "paying", started });
        const waited = record(await native("credits.wait", { above: before, ...(session ? { session } : {}) }));
        if (waited.timedOut === true || typeof waited.available_usd !== "number" || waited.available_usd <= before) {
          setState({ phase: "idle" });
          return;
        }
        setState({ phase: "added", seconds: Math.round((now() - started) / 100) / 10 });
        setDismissed(key);
        onRetry?.();
      })
      .catch(fail);
  };
  const working = state.phase === "working" ? state.what : undefined;
  const currency = new Intl.NumberFormat(currentLanguage(), {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 0,
  });
  let text: string;
  if (state.phase === "paying") text = t("access.paying");
  else if (state.phase === "added") text = t("access.added", { seconds: state.seconds.toFixed(1) });
  else if (state.phase === "failed") text = t("access.failed", { error: state.error });
  else if (need === "credits") text = t("access.credits");
  else if (need === "signedOut") text = t("harness.signedOut", { agent: name });
  else text = t("access.key", { agent: name });
  const showsWays = state.phase !== "paying" && state.phase !== "added";
  return (
    <output
      className="acpmux-host-error acpmux-harness-notice acpmux-access-notice"
      data-access-notice={need ?? "credits"}
      data-access-phase={state.phase}
      {...(state.phase === "added" ? { "data-access-seconds": state.seconds.toFixed(1) } : {})}
      aria-busy={busy || undefined}
    >
      <div className="acpmux-host-error-card">
        <p className="acpmux-host-error-message">
          {text}
          {busy && <Spinner size={12} className="acpmux-harness-spinner" loading />}
        </p>
        {showsWays && need !== "credits" && !canUseCredits && (
          <p className="acpmux-host-error-message text-muted">{t("access.creditsElsewhere", { agent: name })}</p>
        )}
        {state.phase !== "paying" && (
          <div className="acpmux-host-error-actions">
            <button
              type="button"
              data-notice-action="dismiss"
              data-access-action="dismiss"
              disabled={busy}
              onClick={() => {
                setDismissed(key);
                setState({ phase: "idle" });
              }}
            >
              {t("harness.notNow")}
            </button>
            {!showsWays ? null : need === "credits" ? (
              AMOUNTS.map((usd) => (
                <button
                  key={usd}
                  type="button"
                  data-access-amount={String(usd)}
                  disabled={busy}
                  onClick={() => topUp(usd)}
                >
                  {currency.format(usd)}
                </button>
              ))
            ) : (
              <>
                {need === "signedOut" && onLogIn && (
                  <button type="button" data-access-action="login" disabled={busy} onClick={onLogIn}>
                    {t("harness.logIn")}
                  </button>
                )}
                <button type="button" data-access-action="addKey" disabled={busy} onClick={addKey}>
                  {working === "addKey" ? t("access.addingKey") : t("access.addKey")}
                </button>
                {canUseCredits && (
                  <button type="button" data-access-action="useCredits" disabled={busy} onClick={useCredits}>
                    {working === "useCredits" ? t("access.movingToCredits") : t("access.useCredits")}
                  </button>
                )}
              </>
            )}
          </div>
        )}
      </div>
    </output>
  );
}
