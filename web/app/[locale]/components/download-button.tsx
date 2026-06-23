"use client";

import { Menu } from "@base-ui-components/react/menu";
import { useTranslations } from "next-intl";
import posthog from "posthog-js";
import { useState } from "react";
import { Link, usePathname } from "../../../i18n/navigation";
import {
  DOWNLOAD_CONFIRMATION_HREF,
  DOWNLOAD_CONFIRMATION_PATH,
  DOWNLOAD_URL,
  IOS_FOUNDERS_EDITION_URL,
  WAITLIST_PLATFORMS,
  type WaitlistPlatform,
} from "../../lib/download";
import { ctaButtonStyle } from "./cta-styles";
import { WaitlistDialog } from "./waitlist-dialog";

export function DownloadButton({
  size = "default",
  location = "hero",
  className,
}: {
  size?: "default" | "sm";
  location?: string;
  className?: string;
}) {
  const t = useTranslations("common");
  const tp = useTranslations("platforms");
  const pathname = usePathname();
  const isSmall = size === "sm";
  const [waitlistPlatform, setWaitlistPlatform] =
    useState<WaitlistPlatform | null>(null);

  // On the confirmation page itself, navigating to the same route is a no-op
  // (the page stays mounted, so its auto-download won't re-fire). Point the CTA
  // straight at the asset there so it still works as a retry; everywhere else
  // it navigates same-tab to the confirmation page (no popup, no new tab).
  const onConfirmationPage = pathname === DOWNLOAD_CONFIRMATION_PATH;
  const macHref = onConfirmationPage ? DOWNLOAD_URL : DOWNLOAD_CONFIRMATION_HREF;

  // The split button is one pill with two zones (Mac download + platform caret)
  // that tint independently on hover. `overflow-hidden` clips the hover tint to
  // the rounded corners; the divider and caret are kept barely-there so the
  // split affordance only surfaces when you reach for it.
  const downloadZone = `flex items-center transition-colors hover:bg-background/[0.06] ${
    isSmall
      ? "gap-2 pl-4 pr-3 py-1.5 text-xs"
      : "gap-2.5 pl-5 pr-4 py-2.5 text-[15px]"
  }`;
  const caretZone = `group flex items-center justify-center transition-colors hover:bg-background/[0.06] data-[popup-open]:bg-background/[0.06] ${
    isSmall ? "px-2" : "px-2.5"
  }`;

  const captureMac = () =>
    posthog.capture("cmuxterm_download_clicked", { location, platform: "mac" });

  // The Apple mark artwork has an 814:1000 aspect ratio. Derive the box width
  // from its height so the glyph fills the frame instead of letterboxing inside
  // an over-wide box, and nudge it onto the label's cap-height midline.
  const logoHeight = isSmall ? 14 : 19;
  const logoWidth = (logoHeight * 814) / 1000;
  const logoNudge = isSmall ? -0.25 : -0.5;
  const macIcon = (
    <svg
      width={logoWidth}
      height={logoHeight}
      viewBox="0 0 814 1000"
      fill="currentColor"
      style={{ transform: `translateY(${logoNudge}px)` }}
      aria-hidden="true"
    >
      <path d="M788.1 340.9c-5.8 4.5-108.2 62.2-108.2 190.5 0 148.4 130.3 200.9 134.2 202.2-.6 3.2-20.7 71.9-68.7 141.9-42.8 61.6-87.5 123.1-155.5 123.1s-85.5-39.5-164-39.5c-76.5 0-103.7 40.8-165.9 40.8s-105.6-57.8-155.5-127.4c-58.3-81.6-105.6-208.4-105.6-328.6 0-193 125.6-295.5 249.2-295.5 65.7 0 120.5 43.1 161.7 43.1 39.2 0 100.4-45.8 175.1-45.8 28.3 0 130.3 2.6 197.2 99.2zM554.1 159.4c31.1-36.9 53.1-88.1 53.1-139.3 0-7.1-.6-14.3-1.9-20.1-50.6 1.9-110.8 33.7-147.1 75.8-28.9 32.4-57.2 83.6-57.2 135.4 0 7.8 1.3 15.6 1.9 18.1 3.2.6 8.4 1.3 13.6 1.3 45.4 0 102.5-30.4 137.6-71.2z" />
    </svg>
  );

  const caretIcon = (
    <svg
      width={isSmall ? 11 : 13}
      height={isSmall ? 11 : 13}
      viewBox="0 0 12 12"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="opacity-50 transition-opacity group-hover:opacity-100 group-data-[popup-open]:opacity-100"
      aria-hidden="true"
    >
      <path d="M3 4.5 6 7.5 9 4.5" />
    </svg>
  );

  return (
    <>
      <div
        className={`inline-flex items-stretch overflow-hidden whitespace-nowrap rounded-full bg-foreground font-medium ${
          className ?? ""
        }`}
        style={ctaButtonStyle}
      >
        {onConfirmationPage ? (
          <a href={macHref} onClick={captureMac} className={downloadZone}>
            {macIcon}
            {t("downloadForMac")}
          </a>
        ) : (
          <Link href={macHref} onClick={captureMac} className={downloadZone}>
            {macIcon}
            {t("downloadForMac")}
          </Link>
        )}

        <div className="my-2 w-px bg-background/10" aria-hidden="true" />

        <Menu.Root>
          <Menu.Trigger className={caretZone} aria-label={t("otherPlatforms")}>
            {caretIcon}
          </Menu.Trigger>
          <Menu.Portal>
            <Menu.Positioner
              side="bottom"
              align="end"
              sideOffset={8}
              className="z-[1000]"
            >
              <Menu.Popup className="z-[1000] min-w-44 origin-[var(--transform-origin)] rounded-lg border border-border bg-background p-1.5 text-foreground shadow-xl shadow-black/10 outline-none transition duration-150 data-[ending-style]:scale-95 data-[ending-style]:opacity-0 data-[starting-style]:scale-95 data-[starting-style]:opacity-0">
                <Menu.Item
                  render={
                    onConfirmationPage ? (
                      <a href={macHref} />
                    ) : (
                      <Link href={macHref} />
                    )
                  }
                  onClick={captureMac}
                  className={menuItemClass}
                >
                  {tp("macos")}
                </Menu.Item>
                <Menu.Item
                  render={
                    <a
                      href={IOS_FOUNDERS_EDITION_URL}
                      target="_blank"
                      rel="noreferrer"
                    />
                  }
                  onClick={() =>
                    posthog.capture("cmuxterm_download_clicked", {
                      location,
                      platform: "ios",
                    })
                  }
                  className={menuItemClass}
                >
                  <span>{tp("ios")}</span>
                  <ExternalLinkIcon />
                </Menu.Item>
                <Menu.Separator className="mx-1 my-1.5 h-px bg-border" />
                {WAITLIST_PLATFORMS.map((platform) => (
                  <Menu.Item
                    key={platform}
                    onClick={() => {
                      posthog.capture("cmuxterm_waitlist_opened", {
                        location,
                        platform,
                      });
                      setWaitlistPlatform(platform);
                    }}
                    className={menuItemClass}
                  >
                    {tp(platform)}
                  </Menu.Item>
                ))}
              </Menu.Popup>
            </Menu.Positioner>
          </Menu.Portal>
        </Menu.Root>
      </div>

      <WaitlistDialog
        target={waitlistPlatform}
        targetLabel={waitlistPlatform ? tp(waitlistPlatform) : ""}
        open={waitlistPlatform !== null}
        onOpenChange={(open) => {
          if (!open) setWaitlistPlatform(null);
        }}
        location={location}
      />
    </>
  );
}

const menuItemClass =
  "flex min-h-9 cursor-default select-none items-center justify-between gap-6 rounded-md px-2.5 py-2 text-sm text-foreground no-underline outline-none data-[highlighted]:bg-code-bg";

function ExternalLinkIcon() {
  return (
    <svg
      width="13"
      height="13"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="text-muted"
      aria-hidden="true"
    >
      <path d="M6 3.5H3.5v9h9V10" />
      <path d="M9.5 3.5h3v3" />
      <path d="m12.5 3.5-5 5" />
    </svg>
  );
}
