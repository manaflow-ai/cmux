"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import { useTranslations } from "next-intl";
import posthog from "posthog-js";
import { useState } from "react";
import {
  WAITLIST_PLATFORMS,
  type WaitlistTarget,
} from "../../lib/download";

// Pragmatic email check: requires something@something.tld without whitespace.
// The real validation is PostHog-side; this only catches obvious typos before
// we record the signup.
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

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
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Backdrop className="fixed inset-0 z-[1000] bg-black/40 backdrop-blur-sm transition-opacity duration-150 data-[ending-style]:opacity-0 data-[starting-style]:opacity-0" />
        <Dialog.Viewport className="fixed inset-0 z-[1000] flex items-center justify-center overflow-y-auto p-4">
          <Dialog.Popup className="w-full max-w-md rounded-2xl border border-border bg-background p-6 text-foreground shadow-xl shadow-black/10 outline-none transition-opacity duration-150 data-[ending-style]:opacity-0 data-[starting-style]:opacity-0">
            {/* Remount the body per open so its email/status state starts fresh
                (the popup itself stays mounted to play the exit animation). */}
            {target ? (
              <WaitlistBody
                key={target}
                target={target}
                targetLabel={targetLabel}
                location={location}
              />
            ) : null}
          </Dialog.Popup>
        </Dialog.Viewport>
      </Dialog.Portal>
    </Dialog.Root>
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
  const [status, setStatus] = useState<"idle" | "error" | "done">("idle");
  const isAny = target === "any";

  const handleSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const trimmed = email.trim();
    if (!EMAIL_PATTERN.test(trimmed)) {
      setStatus("error");
      return;
    }
    const platforms = isAny ? [...WAITLIST_PLATFORMS] : [target];
    posthog.capture("cmuxterm_waitlist_signup", {
      platforms,
      email: trimmed,
      location,
    });
    // Attach the email to the person so the signup is queryable per visitor.
    posthog.setPersonProperties({
      email: trimmed,
      ...Object.fromEntries(platforms.map((p) => [`waitlist_${p}`, true])),
    });
    setStatus("done");
  };

  if (status === "done") {
    return (
      <div className="flex flex-col">
        <Dialog.Title className="text-lg font-semibold tracking-tight">
          {t("successTitle")}
        </Dialog.Title>
        <Dialog.Description className="mt-2 text-[15px] text-muted" style={{ lineHeight: 1.5 }}>
          {isAny ? t("successBodyAny") : t("successBody", { platform: targetLabel })}
        </Dialog.Description>
        <div className="mt-6 flex justify-end">
          <Dialog.Close
            autoFocus
            className="inline-flex items-center justify-center rounded-full bg-foreground px-5 py-2.5 text-sm font-medium hover:opacity-85 transition-opacity"
            style={{ color: "var(--background)" }}
          >
            {t("done")}
          </Dialog.Close>
        </div>
      </div>
    );
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col">
      <Dialog.Title className="text-lg font-semibold tracking-tight">
        {isAny ? t("titleAny") : t("title", { platform: targetLabel })}
      </Dialog.Title>
      <Dialog.Description className="mt-2 text-[15px] text-muted" style={{ lineHeight: 1.5 }}>
        {isAny ? t("descriptionAny") : t("description", { platform: targetLabel })}
      </Dialog.Description>

      <label htmlFor="waitlist-email" className="mt-5 text-sm font-medium">
        {t("emailLabel")}
      </label>
      <input
        id="waitlist-email"
        type="email"
        autoComplete="email"
        autoFocus
        required
        value={email}
        onChange={(event) => {
          setEmail(event.target.value);
          if (status === "error") setStatus("idle");
        }}
        placeholder={t("emailPlaceholder")}
        aria-invalid={status === "error"}
        aria-describedby={status === "error" ? "waitlist-email-error" : undefined}
        className="mt-1.5 w-full rounded-lg border border-border bg-background px-3 py-2.5 text-[15px] outline-none transition-colors focus:border-foreground aria-[invalid=true]:border-red-500"
      />
      {status === "error" ? (
        <p id="waitlist-email-error" role="alert" className="mt-1.5 text-sm text-red-500">
          {t("invalidEmail")}
        </p>
      ) : null}

      <div className="mt-6 flex justify-end gap-2">
        <Dialog.Close className="inline-flex items-center justify-center rounded-full border border-border px-5 py-2.5 text-sm font-medium text-foreground hover:bg-code-bg transition-colors">
          {t("cancel")}
        </Dialog.Close>
        <button
          type="submit"
          className="inline-flex items-center justify-center rounded-full bg-foreground px-5 py-2.5 text-sm font-medium hover:opacity-85 transition-opacity"
          style={{ color: "var(--background)" }}
        >
          {t("join")}
        </button>
      </div>
    </form>
  );
}
