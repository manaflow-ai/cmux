"use client";

import { useTranslations } from "next-intl";
import posthog from "posthog-js";
import { useState } from "react";
import { Link } from "../../../i18n/navigation";
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
          windows: (chunks) => (
            <Link
              href="/windows"
              onClick={() =>
                posthog.capture("cmux_browser_platform_page_clicked", {
                  location: LOCATION,
                  platform: "windows",
                })
              }
              className={linkClass}
            >
              {chunks}
            </Link>
          ),
          linux: (chunks) => (
            <Link
              href="/linux"
              onClick={() =>
                posthog.capture("cmux_browser_platform_page_clicked", {
                  location: LOCATION,
                  platform: "linux",
                })
              }
              className={linkClass}
            >
              {chunks}
            </Link>
          ),
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
