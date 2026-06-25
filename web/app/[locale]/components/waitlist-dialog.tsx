"use client";

import { Checkbox } from "@base-ui-components/react/checkbox";
import { Dialog } from "@base-ui-components/react/dialog";
import { useTranslations } from "next-intl";
import posthog from "posthog-js";
import { useRef, useState } from "react";
import {
  WAITLIST_EARLY_ACCESS_FLAGS,
  WAITLIST_PLATFORMS,
  type WaitlistPlatform,
  type WaitlistTarget,
} from "../../lib/download";
import { Modal } from "./modal";

// Pragmatic email check: requires something@something.tld without whitespace.
// The real validation is PostHog-side; this only catches obvious typos before
// we record the signup.
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// Minimum spinner duration so a fast request still feels like a considered
// submit rather than an instant flash. The real wait is the capture POST below.
const SUBMIT_DELAY_MS = 600;

/**
 * Records a waitlist signup by POSTing the event straight to PostHog's capture
 * endpoint and awaiting delivery, so the UI shows success only when the record
 * is actually accepted (posthog-js `capture` is fire-and-forget). The event
 * `$set`s the email and Early Access enrollment, so the signup persists
 * server-side even if the SDK's own requests are blocked. Returns whether the
 * server accepted it.
 */
async function recordWaitlistSignup(
  email: string,
  platforms: WaitlistPlatform[],
  location: string,
): Promise<boolean> {
  const host = posthog.config?.api_host;
  const token = posthog.config?.token;
  if (!host || !token) return false;
  const enrollment = Object.fromEntries(
    platforms.map((p) => [
      `$feature_enrollment/${WAITLIST_EARLY_ACCESS_FLAGS[p]}`,
      true,
    ]),
  );
  try {
    // `/e/` is the capture endpoint posthog-js itself posts events to (through
    // the same first-party `api_host` proxy), so this matches the SDK's path
    // and payload shape rather than inventing a new one.
    const res = await fetch(`${host.replace(/\/+$/, "")}/e/`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      keepalive: true,
      body: JSON.stringify({
        api_key: token,
        event: "cmuxterm_waitlist_signup",
        properties: {
          distinct_id: email,
          email,
          platforms,
          location,
          $set: { email, ...enrollment },
          $set_once: { waitlist_email: email },
        },
        timestamp: new Date().toISOString(),
      }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

/**
 * Asks the server whether the email's domain can receive mail (MX + disposable
 * check) before we record the signup. Returns `"invalid"` only on a definitive
 * rejection; network or server errors return `"ok"` so a transient failure never
 * blocks a real signup (the server itself also fails open on DNS hiccups).
 */
async function verifyWaitlistEmail(
  email: string,
  platforms: WaitlistPlatform[],
  location: string,
): Promise<"ok" | "invalid"> {
  try {
    const res = await fetch("/api/waitlist", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, platforms, location, notify: false }),
    });
    if (!res.ok) return "ok";
    const data = (await res.json().catch(() => null)) as {
      valid?: boolean;
    } | null;
    return data?.valid === false ? "invalid" : "ok";
  } catch {
    return "ok";
  }
}

/**
 * Pings our Slack channel about a signup via the `/api/waitlist` route.
 * Best-effort: the durable record is the PostHog capture above, so a failed
 * notification never blocks or fails the signup.
 */
async function notifyWaitlistSlack(
  email: string,
  platforms: WaitlistPlatform[],
  location: string,
): Promise<void> {
  try {
    await fetch("/api/waitlist", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      keepalive: true,
      body: JSON.stringify({ email, platforms, location, notify: true }),
    });
  } catch {
    // Notification only; ignore failures.
  }
}

export function WaitlistDialog({
  target,
  open,
  onOpenChange,
  location,
}: {
  /** Platform the signup is for, or `"any"` for the generic entry. */
  target: WaitlistTarget | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  location: string;
}) {
  // Keep the last opened target (with a per-open key) mounted through the
  // modal's exit animation, instead of vanishing the instant the parent clears
  // `target`. A fresh key on each open resets the body's form state.
  const [session, setSession] = useState({ target, key: 0 });
  const [prevOpen, setPrevOpen] = useState(open);
  if (open !== prevOpen) {
    setPrevOpen(open);
    if (open && target) {
      setSession((s) => ({ target, key: s.key + 1 }));
    }
  }

  return (
    <Modal open={open} onOpenChange={onOpenChange}>
      {session.target ? (
        <WaitlistBody
          key={session.key}
          target={session.target}
          location={location}
        />
      ) : null}
    </Modal>
  );
}

function WaitlistBody({
  target,
  location,
}: {
  target: WaitlistTarget;
  location: string;
}) {
  const t = useTranslations("waitlist");
  const tp = useTranslations("platforms");
  const isAny = target === "any";
  const targetLabel = isAny ? "" : tp(target);
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<
    "idle" | "error" | "submitting" | "sendError" | "done"
  >("idle");
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // The generic dialog forces the visitor to choose which platforms to join
  // (none checked by default); a per-platform entry is fixed to that one.
  const [selected, setSelected] = useState<Set<WaitlistPlatform>>(
    () => new Set(),
  );
  const [platformError, setPlatformError] = useState(false);
  const chosen = isAny
    ? WAITLIST_PLATFORMS.filter((p) => selected.has(p))
    : [target as WaitlistPlatform];
  const togglePlatform = (p: WaitlistPlatform) => {
    setPlatformError(false);
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(p)) next.delete(p);
      else next.add(p);
      return next;
    });
  };

  const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (status === "submitting") return;
    if (isAny && chosen.length === 0) {
      setPlatformError(true);
      return;
    }
    const trimmed = email.trim();
    if (!EMAIL_PATTERN.test(trimmed)) {
      setStatus("error");
      return;
    }
    setStatus("submitting");
    const platforms = chosen;
    // Start the pleasant-spinner clock now so the server round trips overlap it
    // rather than stacking on top.
    const minSpinner = new Promise<void>((resolve) => {
      timerRef.current = setTimeout(resolve, SUBMIT_DELAY_MS);
    });
    // Gate on server-side deliverability (MX + disposable) before recording, so
    // bogus addresses never enter the waitlist. Fails open on transient errors.
    const verdict = await verifyWaitlistEmail(trimmed, platforms, location);
    if (verdict === "invalid") {
      if (timerRef.current) clearTimeout(timerRef.current);
      setStatus("error");
      return;
    }
    // Record the signup with an awaited POST to PostHog's capture endpoint
    // (success only shows on confirmed delivery). The event carries
    // `distinct_id: email` and `$set`s the email + Early Access enrollment, so
    // the waitlist person/enrollee is created under that email. We deliberately
    // do NOT call `posthog.identify`, which would rewrite the visitor's live
    // session identity to the waitlist email and deanonymize their own
    // analytics; their browsing stays anonymous. A minimum delay keeps the
    // spinner pleasant when the request is fast.
    const [ok] = await Promise.all([
      recordWaitlistSignup(trimmed, platforms, location),
      minSpinner,
    ]);
    // Ping Slack only after the signup was durably recorded, so the channel
    // never reports a signup that actually failed. Best-effort, not awaited.
    if (ok) {
      void notifyWaitlistSlack(trimmed, platforms, location);
    }
    setStatus(ok ? "done" : "sendError");
  };

  const submitting = status === "submitting";

  // The form stays mounted across idle/error/submitting/done and defines the
  // dialog's height; the success view is overlaid absolutely on top, so the
  // modal never resizes between states (zero layout shift).
  const done = status === "done";

  return (
    <div className="relative">
      <form
        onSubmit={handleSubmit}
        // `inert` when done keeps the form mounted (it defines the dialog
        // height for zero layout shift) but removes its controls from the tab
        // order and the accessibility tree, so keyboard users can't reach the
        // hidden inputs under the success overlay.
        inert={done}
        className={`flex flex-col transition-opacity duration-300 ease-out ${
          done ? "opacity-0" : "opacity-100"
        }`}
      >
        <Dialog.Title className="text-lg font-semibold tracking-tight">
          {isAny ? t("titleAny") : t("title", { platform: targetLabel })}
        </Dialog.Title>
        <Dialog.Description className="mt-2 text-[15px] text-muted" style={{ lineHeight: 1.5 }}>
          {isAny ? t("descriptionAny") : t("description", { platform: targetLabel })}
        </Dialog.Description>

        {isAny ? (
          <fieldset className="relative mt-5">
            <legend className="text-sm font-medium">{t("platformsLabel")}</legend>
            <div className="mt-2 flex flex-col">
              {WAITLIST_PLATFORMS.map((p) => (
                <label
                  key={p}
                  className="flex cursor-pointer select-none items-center gap-2.5 py-1.5"
                >
                  <Checkbox.Root
                    aria-label={tp(p)}
                    checked={selected.has(p)}
                    onCheckedChange={() => togglePlatform(p)}
                    disabled={submitting}
                    className="flex h-[18px] w-[18px] shrink-0 items-center justify-center rounded-[5px] border border-border transition-colors data-[checked]:border-foreground data-[checked]:bg-foreground"
                  >
                    <Checkbox.Indicator className="flex">
                      <svg
                        width="12"
                        height="12"
                        viewBox="0 0 24 24"
                        fill="none"
                        stroke="var(--background)"
                        strokeWidth="3.5"
                        strokeLinecap="round"
                        strokeLinejoin="round"
                        aria-hidden="true"
                      >
                        <path d="m5 13 4 4L19 7" />
                      </svg>
                    </Checkbox.Indicator>
                  </Checkbox.Root>
                  <span className="text-[15px]">{tp(p)}</span>
                </label>
              ))}
            </div>
            {/* Absolute so the validation message never shifts the layout. */}
            {platformError ? (
              <p
                role="alert"
                className="absolute left-0 top-full text-sm text-red-500"
              >
                {t("selectPlatform")}
              </p>
            ) : null}
          </fieldset>
        ) : null}

        <label htmlFor="waitlist-email" className="mt-5 text-sm font-medium">
          {t("emailLabel")}
        </label>
        <div className="relative">
          <input
            id="waitlist-email"
            type="email"
            autoComplete="email"
            autoFocus
            required
            value={email}
            disabled={submitting}
            onChange={(event) => {
              setEmail(event.target.value);
              if (status === "error" || status === "sendError") setStatus("idle");
            }}
            placeholder={t("emailPlaceholder")}
            aria-invalid={status === "error"}
            aria-describedby={status === "error" ? "waitlist-email-error" : undefined}
            className="mt-1.5 w-full rounded-lg border border-border bg-background px-3 py-2.5 text-[15px] outline-none transition-colors focus:border-foreground aria-[invalid=true]:border-red-500 disabled:opacity-60"
          />
          {/* Absolutely positioned in the gap below the input so the error
              never pushes the buttons down (no shift on the error states). */}
          {status === "error" || status === "sendError" ? (
            <p
              id="waitlist-email-error"
              role="alert"
              className="absolute left-0 top-full mt-1 text-sm text-red-500"
            >
              {status === "sendError" ? t("sendError") : t("invalidEmail")}
            </p>
          ) : null}
        </div>

        <div className="mt-6 flex justify-end gap-2">
          <Dialog.Close
            disabled={submitting}
            className="inline-flex items-center justify-center rounded-full border border-border px-5 py-2.5 text-sm font-medium text-foreground transition-colors hover:bg-code-bg disabled:opacity-50"
          >
            {t("cancel")}
          </Dialog.Close>
          <button
            type="submit"
            disabled={submitting}
            aria-busy={submitting}
            className="relative inline-flex items-center justify-center rounded-full bg-foreground px-5 py-2.5 text-sm font-medium transition-opacity hover:opacity-85 disabled:opacity-100 disabled:hover:opacity-100"
            style={{ color: "var(--background)" }}
          >
            {/* Label and spinner cross-fade in place so the button morphs
                between states instead of hard-swapping its contents. */}
            <span
              className={`flex items-center gap-2 transition-opacity duration-200 ease-out ${
                submitting ? "opacity-0" : "opacity-100"
              }`}
            >
              {t("join")}
            </span>
            <span
              aria-hidden="true"
              className={`absolute inset-0 flex items-center justify-center gap-2 transition-opacity duration-200 ease-out ${
                submitting ? "opacity-100" : "opacity-0"
              }`}
            >
              <Spinner />
              {t("joining")}
            </span>
          </button>
        </div>
      </form>

      {done ? (
        <div
          role="status"
          className="absolute inset-0 flex flex-col items-center justify-center text-center"
        >
          {/* Checkmark pops in from the @starting-style (Tailwind `starting:`). */}
          <div className="flex h-14 w-14 items-center justify-center rounded-full bg-foreground transition-all duration-500 ease-out starting:scale-50 starting:opacity-0">
            <svg
              width="26"
              height="26"
              viewBox="0 0 24 24"
              fill="none"
              stroke="var(--background)"
              strokeWidth="2.5"
              strokeLinecap="round"
              strokeLinejoin="round"
              aria-hidden="true"
            >
              <path d="m5 13 4 4L19 7" />
            </svg>
          </div>
          <div className="transition-all delay-100 duration-500 ease-out starting:opacity-0">
            <h2 className="mt-5 text-lg font-semibold tracking-tight">
              {t("successTitle")}
            </h2>
            <p className="mt-2 text-[15px] text-muted" style={{ lineHeight: 1.5 }}>
              {isAny ? t("successBodyAny") : t("successBody", { platform: targetLabel })}
            </p>
          </div>
          <Dialog.Close
            autoFocus
            className="mt-6 inline-flex items-center justify-center rounded-full bg-foreground px-5 py-2.5 text-sm font-medium hover:opacity-85 transition-opacity"
            style={{ color: "var(--background)" }}
          >
            {t("done")}
          </Dialog.Close>
        </div>
      ) : null}
    </div>
  );
}

/**
 * A smooth conic-gradient ring spinner that tapers from transparent to the
 * button's text color (`currentColor`), masked to a thin ring.
 */
function Spinner() {
  return (
    <span
      className="h-4 w-4 shrink-0 animate-spin rounded-full"
      style={{
        background:
          "conic-gradient(from 90deg at 50% 50%, transparent 0deg, currentColor 300deg)",
        WebkitMask:
          "radial-gradient(farthest-side, transparent calc(100% - 2px), #000 calc(100% - 2px))",
        mask: "radial-gradient(farthest-side, transparent calc(100% - 2px), #000 calc(100% - 2px))",
      }}
      aria-hidden="true"
    />
  );
}
