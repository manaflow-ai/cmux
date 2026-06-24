"use client";

import { useTranslations } from "next-intl";
import posthog from "posthog-js";
import { useState } from "react";
import { WaitlistDialog } from "./waitlist-dialog";

/**
 * A subtle one-line prompt ("Coming to Linux, Windows, and Android — Join
 * waitlist") that opens the generic waitlist dialog. Use it near a download
 * CTA to point non-macOS visitors at the waitlist.
 */
export function WaitlistCallout({
  location = "bottom",
  className,
}: {
  location?: string;
  className?: string;
}) {
  const t = useTranslations("waitlist");
  const [open, setOpen] = useState(false);

  return (
    <>
      <p className={`text-sm text-muted ${className ?? ""}`}>
        {t("calloutText")}{" "}
        <button
          type="button"
          onClick={() => {
            posthog.capture("cmuxterm_waitlist_opened", {
              location,
              platform: "any",
            });
            setOpen(true);
          }}
          className="text-foreground underline underline-offset-2 decoration-border transition-colors hover:decoration-foreground"
        >
          {t("join")}
        </button>
      </p>

      <WaitlistDialog
        target={open ? "any" : null}
        open={open}
        onOpenChange={setOpen}
        location={location}
      />
    </>
  );
}
