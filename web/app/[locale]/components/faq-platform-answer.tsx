"use client";

import { useTranslations } from "next-intl";
import posthog from "posthog-js";
import { useState } from "react";
import { WaitlistDialog } from "./waitlist-dialog";

const LOCATION = "faq";

/**
 * Renders the "What platforms does it support?" FAQ answer with an inline
 * trigger that opens the generic waitlist dialog. Client component because the
 * dialog needs open state; the FAQ answer copy carries a `<waitlist>` chunk.
 */
export function FaqPlatformAnswer({ linkClass }: { linkClass: string }) {
  const t = useTranslations("home");
  const [open, setOpen] = useState(false);

  return (
    <>
      <p className="text-muted">
        {t.rich("faqPlatformA", {
          waitlist: (chunks) => (
            <button
              type="button"
              onClick={() => {
                posthog.capture("cmuxterm_waitlist_opened", {
                  location: LOCATION,
                  platform: "any",
                });
                setOpen(true);
              }}
              className={linkClass}
            >
              {chunks}
            </button>
          ),
        })}
      </p>
      <WaitlistDialog
        target={open ? "any" : null}
        open={open}
        onOpenChange={setOpen}
        location={LOCATION}
      />
    </>
  );
}
