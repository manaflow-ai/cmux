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
  WAITLIST_PLATFORMS,
  type WaitlistPlatform,
} from "../../lib/download";
import { ctaButtonStyle } from "./cta-styles";
import { PlatformIcon } from "./platform-icons";
import { WaitlistDialog } from "./waitlist-dialog";

// Optional per-instance padding override in px, used only by the /debug tuner
// to fine-tune both sizes live. When absent (every production call site), the
// Tailwind classes below are the single source of truth and rendering is
// unchanged. downloadRight = gap LEFT of divider; caretLeft = gap RIGHT of it.
export type PadOverride = {
  downloadLeft?: number;
  downloadRight?: number;
  caretLeft?: number;
  caretRight?: number;
};

export function DownloadButton({
  size = "default",
  location = "hero",
  className,
  padOverride,
}: {
  size?: "default" | "sm";
  location?: string;
  className?: string;
  padOverride?: PadOverride;
}) {
  const t = useTranslations("common");
  const tp = useTranslations("platforms");
  const tw = useTranslations("waitlist");
  const pathname = usePathname();
  const isSmall = size === "sm";
  const [waitlistPlatform, setWaitlistPlatform] =
    useState<WaitlistPlatform | null>(null);

  // Open the waitlist dialog on the next frame. Selecting a menu item fires
  // inside a pointer gesture; opening the dialog synchronously lets that same
  // gesture's trailing event count as an outside-press and dismiss the dialog
  // the instant it mounts. Deferring past the gesture lets it open and stay.
  const openWaitlist = (platform: WaitlistPlatform) => {
    requestAnimationFrame(() => setWaitlistPlatform(platform));
  };

  // On the confirmation page itself, navigating to the same route is a no-op
  // (the page stays mounted, so its auto-download won't re-fire). Point the CTA
  // straight at the asset there so it still works as a retry; everywhere else
  // it navigates same-tab to the confirmation page (no popup, no new tab).
  const onConfirmationPage = pathname === DOWNLOAD_CONFIRMATION_PATH;
  const macHref = onConfirmationPage ? DOWNLOAD_URL : DOWNLOAD_CONFIRMATION_HREF;

  // Inline padding overrides win over the Tailwind classes; undefined in prod.
  const downloadStyle = padOverride
    ? { paddingLeft: padOverride.downloadLeft, paddingRight: padOverride.downloadRight }
    : undefined;
  const caretStyle = padOverride
    ? { paddingLeft: padOverride.caretLeft, paddingRight: padOverride.caretRight }
    : undefined;

  // The split button is one pill with two zones (Mac download + platform caret)
  // that tint independently on hover. `overflow-hidden` clips the hover tint to
  // the rounded corners; the divider and caret are kept barely-there so the
  // split affordance only surfaces when you reach for it.
  // In dark mode the pill is light and the divider/caret are dark, which reads
  // higher-contrast than the inverse in light mode, so dial those down further
  // under `dark:` to keep the split affordance equally quiet.
  // Slightly more breathing room after the label than the caret zone's
  // padding, so the divider sits a touch closer to the caret than to "Mac".
  // The hover tint is applied without a CSS transition on purpose: animating
  // background-color/opacity here promotes the sub-pixel-positioned zone into
  // its own WebKit compositing layer, which snaps to the device-pixel grid and
  // makes the label/caret visibly jump on hover (Safari only, worst at the
  // small size). Instant tint avoids the promotion, so nothing shifts.
  const downloadZone = `flex items-center hover:bg-background/[0.04] dark:hover:bg-background/[0.03] ${
    isSmall
      ? "gap-2 pl-3 pr-[7px] py-1.5 text-xs"
      : "gap-2.5 pl-5 pr-2 py-2.5 text-[15px]"
  }`;
  const caretZone = `group flex items-center justify-center hover:bg-background/[0.04] dark:hover:bg-background/[0.03] data-[popup-open]:bg-background/[0.04] dark:data-[popup-open]:bg-background/[0.03] ${
    isSmall ? "pl-[5px] pr-[7px]" : "pl-1.5 pr-[7px]"
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

  // A thin, evenly-weighted chevron (Lucide geometry) — the standard clean
  // dropdown caret. Stays faint, brightening only on hover/open.
  const caretIcon = (
    <svg
      width={isSmall ? 12 : 14}
      height={isSmall ? 12 : 14}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.25"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="opacity-40 group-hover:opacity-70 group-data-[popup-open]:opacity-70 dark:opacity-30 dark:group-hover:opacity-55 dark:group-data-[popup-open]:opacity-55"
      aria-hidden="true"
    >
      <path d="m6 9 6 6 6-6" />
    </svg>
  );

  return (
    <>
      <div
        // No CSS transition on the hover tint and no forced GPU layer (e.g.
        // `translateZ(0)`) on this pill: either one makes WebKit composite the
        // sub-pixel-positioned zones and snap them to the device-pixel grid on
        // hover, which reads as the label/caret jumping (Safari only, worst at
        // the small size). Keeping the hover repaint on the main thread matches
        // Chrome and stays stable; overflow-hidden still clips the tint since
        // the zones never get their own layer.
        className={`inline-flex items-stretch overflow-hidden whitespace-nowrap rounded-full bg-foreground font-medium ${
          className ?? ""
        }`}
        style={ctaButtonStyle}
      >
        {onConfirmationPage ? (
          <a
            href={macHref}
            onClick={captureMac}
            className={downloadZone}
            style={downloadStyle}
          >
            {macIcon}
            {t("downloadForMac")}
          </a>
        ) : (
          <Link
            href={macHref}
            onClick={captureMac}
            className={downloadZone}
            style={downloadStyle}
          >
            {macIcon}
            {t("downloadForMac")}
          </Link>
        )}

        <div className="my-2.5 w-px bg-background/[0.07] dark:bg-background/[0.05]" aria-hidden="true" />

        <Menu.Root>
          <Menu.Trigger
            className={caretZone}
            style={caretStyle}
            aria-label={t("otherPlatforms")}
          >
            {caretIcon}
          </Menu.Trigger>
          <Menu.Portal>
            <Menu.Positioner side="bottom" align="end" sideOffset={8} className="z-[1000]">
              <Menu.Popup className="z-[1000] min-w-52 origin-[var(--transform-origin)] rounded-lg border border-border bg-background p-1.5 text-foreground shadow-xl shadow-black/10 outline-none transition duration-150 ease-out data-[ending-style]:scale-[0.96] data-[ending-style]:opacity-0 data-[starting-style]:scale-[0.96] data-[starting-style]:opacity-0">
                <Menu.Item
                  render={
                    onConfirmationPage ? <a href={macHref} /> : <Link href={macHref} />
                  }
                  onClick={captureMac}
                  className={menuItemClass}
                >
                  <PlatformIcon name="macos" />
                  <span className="flex-1 text-left">{tp("macos")}</span>
                </Menu.Item>
                <Menu.Item
                  render={<Link href="/ios" target="_blank" rel="noreferrer" />}
                  onClick={() =>
                    posthog.capture("cmuxterm_download_clicked", {
                      location,
                      platform: "ios",
                    })
                  }
                  className={menuItemClass}
                >
                  <PlatformIcon name="ios" />
                  <span className="flex-1 text-left">{tp("ios")}</span>
                  <ExternalLinkIcon />
                </Menu.Item>
                <Menu.Separator className="mx-1 my-1.5 h-px bg-border" />
                <Menu.Group>
                  <Menu.GroupLabel className="px-2.5 pb-1 pt-1 text-xs text-muted">
                    {tw("join")}
                  </Menu.GroupLabel>
                  {WAITLIST_PLATFORMS.map((platform) => (
                    <Menu.Item
                      key={platform}
                      onClick={() => {
                        posthog.capture("cmuxterm_waitlist_opened", {
                          location,
                          platform,
                        });
                        openWaitlist(platform);
                      }}
                      className={menuItemClass}
                    >
                      <PlatformIcon name={platform} />
                      <span className="flex-1 text-left">{tp(platform)}</span>
                    </Menu.Item>
                  ))}
                </Menu.Group>
              </Menu.Popup>
            </Menu.Positioner>
          </Menu.Portal>
        </Menu.Root>
      </div>

      <WaitlistDialog
        target={waitlistPlatform}
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
  "flex min-h-9 cursor-default select-none items-center gap-2.5 rounded-md px-2.5 py-2 text-sm text-foreground no-underline outline-none data-[highlighted]:bg-code-bg";

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
