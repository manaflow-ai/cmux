"use client";

import posthog from "posthog-js";
import { useState } from "react";
import {
  ctaButtonBase,
  ctaButtonDefaultSize,
  ctaButtonStyle,
} from "@/app/[locale]/components/cta-styles";
import { WaitlistDialog } from "@/app/[locale]/components/waitlist-dialog";
import type { WaitlistPlatform } from "@/app/lib/download";

/**
 * Card action for a platform that is waitlist-only: opens the shared waitlist
 * form for that platform instead of offering a download.
 */
export function BrowserWaitlistCardAction({
  platform,
  label,
}: {
  readonly platform: WaitlistPlatform;
  /** Localized "Join the <platform> waitlist" label. */
  readonly label: string;
}) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button
        type="button"
        onClick={() => {
          posthog.capture("cmuxterm_waitlist_opened", {
            location: "browser-landing",
            platform,
          });
          setOpen(true);
        }}
        className={`${ctaButtonBase} ${ctaButtonDefaultSize} w-full justify-center`}
        style={ctaButtonStyle}
      >
        <span className="min-w-0 text-balance whitespace-normal text-center">
          {label}
        </span>
      </button>
      <WaitlistDialog
        target={open ? platform : null}
        open={open}
        onOpenChange={setOpen}
        location="browser-landing"
      />
    </>
  );
}
