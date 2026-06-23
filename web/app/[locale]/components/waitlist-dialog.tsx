"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import { useTranslations } from "next-intl";
import posthog from "posthog-js";
import { useRef, useState } from "react";
import {
  WAITLIST_EARLY_ACCESS_FLAGS,
  WAITLIST_PLATFORMS,
  type WaitlistTarget,
} from "../../lib/download";
import { Modal } from "./modal";

// Pragmatic email check: requires something@something.tld without whitespace.
// The real validation is PostHog-side; this only catches obvious typos before
// we record the signup.
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// A short, intentional pause so the submit feels considered: the PostHog calls
// are fire-and-forget (nothing to await), so this is a deliberate delight beat,
// not a real network wait. Kept brief so it never feels like lag.
const SUBMIT_DELAY_MS = 750;

export function WaitlistDialog({
  target,
  targetLabel,
  open,
  onOpenChange,
  location,
}: {
  /** Platform the signup is for, or `"any"` for the generic entry. */
  target: WaitlistTarget | null;
  /** Localized platform name, used in the per-platform copy (ignored for `"any"`). */
  targetLabel: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  location: string;
}) {
  return (
    <Modal open={open} onOpenChange={onOpenChange}>
      {/* Remount the body per open so its email/status state starts fresh
          (the modal popup stays mounted to play the exit animation). */}
      {target ? (
        <WaitlistBody
          key={target}
          target={target}
          targetLabel={targetLabel}
          location={location}
        />
      ) : null}
    </Modal>
  );
}

function WaitlistBody({
  target,
  targetLabel,
  location,
}: {
  target: WaitlistTarget;
  targetLabel: string;
  location: string;
}) {
  const t = useTranslations("waitlist");
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<
    "idle" | "error" | "submitting" | "done"
  >("idle");
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const isAny = target === "any";

  const handleSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (status === "submitting") return;
    const trimmed = email.trim();
    if (!EMAIL_PATTERN.test(trimmed)) {
      setStatus("error");
      return;
    }
    setStatus("submitting");
    const platforms = isAny ? [...WAITLIST_PLATFORMS] : [target];
    // Identify the visitor by the email they gave so the signup becomes a real
    // PostHog person (queryable in People, not just a raw event). `$set_once`
    // keeps `waitlist_email` as the original waitlist address even if the
    // person is later merged. This is the *waitlist* email and may differ from
    // the account email the user eventually signs in with; reconcile at app
    // sign-in by identifying the canonical user id (PostHog aliases the email
    // person into it) rather than treating this as their permanent identity.
    posthog.identify(trimmed, { email: trimmed }, { waitlist_email: trimmed });
    posthog.capture("cmuxterm_waitlist_signup", {
      platforms,
      email: trimmed,
      location,
    });
    // Enroll the identified person in each platform's Early Access Feature so
    // the signup shows up as a managed enrollee in PostHog, not just an event.
    for (const p of platforms) {
      posthog.updateEarlyAccessFeatureEnrollment(
        WAITLIST_EARLY_ACCESS_FLAGS[p],
        true,
        "concept",
      );
    }
    timerRef.current = setTimeout(() => setStatus("done"), SUBMIT_DELAY_MS);
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
        aria-hidden={done}
        className={`flex flex-col ${done ? "invisible" : ""}`}
      >
        <Dialog.Title className="text-lg font-semibold tracking-tight">
          {isAny ? t("titleAny") : t("title", { platform: targetLabel })}
        </Dialog.Title>
        <Dialog.Description className="mt-2 text-[15px] text-muted" style={{ lineHeight: 1.5 }}>
          {isAny ? t("descriptionAny") : t("description", { platform: targetLabel })}
        </Dialog.Description>

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
              if (status === "error") setStatus("idle");
            }}
            placeholder={t("emailPlaceholder")}
            aria-invalid={status === "error"}
            aria-describedby={status === "error" ? "waitlist-email-error" : undefined}
            className="mt-1.5 w-full rounded-lg border border-border bg-background px-3 py-2.5 text-[15px] outline-none transition-colors focus:border-foreground aria-[invalid=true]:border-red-500 disabled:opacity-60"
          />
          {/* Absolutely positioned in the gap below the input so the error
              never pushes the buttons down (no shift on the error state). */}
          {status === "error" ? (
            <p
              id="waitlist-email-error"
              role="alert"
              className="absolute left-0 top-full mt-1 text-sm text-red-500"
            >
              {t("invalidEmail")}
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
            className="inline-flex min-w-[7.5rem] items-center justify-center gap-2 rounded-full bg-foreground px-5 py-2.5 text-sm font-medium transition-opacity hover:opacity-85 disabled:opacity-90"
            style={{ color: "var(--background)" }}
          >
            {submitting ? (
              <>
                <Spinner />
                {t("joining")}
              </>
            ) : (
              t("join")
            )}
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

/** A small spinning ring that inherits the button's text color. */
function Spinner() {
  return (
    <svg
      className="h-4 w-4 animate-spin"
      viewBox="0 0 24 24"
      fill="none"
      aria-hidden="true"
    >
      <circle
        cx="12"
        cy="12"
        r="9"
        stroke="currentColor"
        strokeOpacity="0.25"
        strokeWidth="3"
      />
      <path
        d="M21 12a9 9 0 0 0-9-9"
        stroke="currentColor"
        strokeWidth="3"
        strokeLinecap="round"
      />
    </svg>
  );
}
