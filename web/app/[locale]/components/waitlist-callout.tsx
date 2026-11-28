"use client";

import { useTranslations } from "next-intl";
import posthog from "posthog-js";
import { useState } from "react";
import { WaitlistDialog } from "./waitlist-dialog";

/** Opens the generic waitlist dialog from a subtle one-line release prompt. */
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
          className="text-foreground underline underline-offset-2 decoration-link-underline transition-colors hover:decoration-foreground"
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
