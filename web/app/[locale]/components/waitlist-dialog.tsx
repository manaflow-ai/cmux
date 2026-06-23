"use client";

import { Dialog } from "@base-ui-components/react/dialog";
import { useTranslations } from "next-intl";
import posthog from "posthog-js";
import { useState } from "react";
import type { WaitlistPlatform } from "../../lib/download";

// Pragmatic email check: requires something@something.tld without whitespace.
// The real validation is PostHog-side; this only catches obvious typos before
// we record the signup.
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function WaitlistDialog({
  platform,
  platformLabel,
  open,
  onOpenChange,
  location,
}: {
  platform: WaitlistPlatform | null;
  platformLabel: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  location: string;
}) {
  const t = useTranslations("waitlist");
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<"idle" | "error" | "done">("idle");

  const reset = () => {
    setEmail("");
    setStatus("idle");
  };

  const handleOpenChange = (next: boolean) => {
    // Clear the form as the dialog dismisses so the next platform opens fresh.
    if (!next) reset();
    onOpenChange(next);
  };

  const handleSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const trimmed = email.trim();
    if (!EMAIL_PATTERN.test(trimmed)) {
      setStatus("error");
      return;
    }
    if (platform) {
      posthog.capture("cmuxterm_waitlist_signup", {
        platform,
        email: trimmed,
        location,
      });
      // Attach the email to the person so the signup is queryable per visitor.
      posthog.setPersonProperties({
        email: trimmed,
        [`waitlist_${platform}`]: true,
      });
    }
    setStatus("done");
  };

  return (
    <Dialog.Root open={open} onOpenChange={handleOpenChange}>
      <Dialog.Portal>
        <Dialog.Backdrop className="fixed inset-0 z-[1000] bg-black/40 backdrop-blur-sm transition-opacity duration-150 data-[ending-style]:opacity-0 data-[starting-style]:opacity-0" />
        <Dialog.Viewport className="fixed inset-0 z-[1000] flex items-center justify-center overflow-y-auto p-4">
          <Dialog.Popup className="w-full max-w-md rounded-2xl border border-border bg-background p-6 shadow-xl shadow-black/10 outline-none transition-all duration-150 data-[ending-style]:scale-95 data-[ending-style]:opacity-0 data-[starting-style]:scale-95 data-[starting-style]:opacity-0">
            {status === "done" ? (
              <div className="flex flex-col">
                <Dialog.Title className="text-lg font-semibold tracking-tight">
                  {t("successTitle")}
                </Dialog.Title>
                <Dialog.Description className="mt-2 text-[15px] text-muted" style={{ lineHeight: 1.5 }}>
                  {t("successBody", { platform: platformLabel })}
                </Dialog.Description>
                <div className="mt-6 flex justify-end">
                  <Dialog.Close className="inline-flex items-center justify-center rounded-full bg-foreground px-5 py-2.5 text-sm font-medium hover:opacity-85 transition-opacity" style={{ color: "var(--background)" }}>
                    {t("done")}
                  </Dialog.Close>
                </div>
              </div>
            ) : (
              <form onSubmit={handleSubmit} className="flex flex-col">
                <Dialog.Title className="text-lg font-semibold tracking-tight">
                  {t("title", { platform: platformLabel })}
                </Dialog.Title>
                <Dialog.Description className="mt-2 text-[15px] text-muted" style={{ lineHeight: 1.5 }}>
                  {t("description", { platform: platformLabel })}
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
                  className="mt-1.5 w-full rounded-lg border border-border bg-background px-3 py-2.5 text-[15px] outline-none transition-colors focus:border-foreground aria-[invalid=true]:border-red-500"
                />
                {status === "error" ? (
                  <p className="mt-1.5 text-sm text-red-500">{t("invalidEmail")}</p>
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
                    {t("submit")}
                  </button>
                </div>
              </form>
            )}
          </Dialog.Popup>
        </Dialog.Viewport>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
