"use client";

import { useTranslations } from "next-intl";
import { Link } from "../../../i18n/navigation";
import { NavLinks } from "./nav-links";
import { DownloadButton } from "./download-button";
import { ThemeToggle } from "../theme";
import { GitHubStarsBadge } from "./github-stars";
import {
  useMobileDrawer,
  MobileDrawerOverlay,
  MobileDrawerToggle,
} from "./mobile-drawer";

export function SiteHeader({
  section,
  hideLogo,
}: {
  section?: string;
  hideLogo?: boolean;
}) {
  const t = useTranslations("nav");
  const tc = useTranslations("common");
  const { open, toggle, close, drawerRef, buttonRef } = useMobileDrawer();

  return (
    <>
      <header className="sticky top-0 z-30 w-full bg-background">
        <div className="w-full max-w-6xl mx-auto flex h-12 items-center px-6 min-[940px]:grid min-[940px]:grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] min-[940px]:gap-4">
          {/* Left: logo + section */}
          <div className="flex min-w-0 items-center gap-3">
            {!hideLogo && (
              <>
                <Link href="/" className="flex items-center gap-2.5">
                  <img
                    src="/logo.png"
                    alt="cmux"
                    width={24}
                    height={24}
                    className="rounded-md"
                  />
                  <span className="text-sm font-semibold tracking-tight">
                    cmux
                  </span>
                </Link>
                {section && (
                  <>
                    <span className="text-border text-[13px]">/</span>
                    <span className="text-[13px] text-muted">{section}</span>
                  </>
                )}
              </>
            )}
          </div>

          {/* Center: nav links */}
          <nav className="hidden min-w-0 items-center justify-center gap-4 text-sm text-muted min-[940px]:flex">
            <NavLinks />
          </nav>

          {/* Right: GitHub stars + Download + theme + mobile */}
          <div className="ml-auto flex min-w-0 items-center justify-end gap-3 min-[940px]:ml-0">
            <GitHubStarsBadge />
            <div className="hidden min-[940px]:block">
              <DownloadButton size="sm" location="navbar" />
            </div>
            <ThemeToggle />
            <MobileDrawerToggle
              open={open}
              onClick={toggle}
              buttonRef={buttonRef}
            />
          </div>
        </div>
      </header>

      {/* Mobile overlay + drawer */}
      <MobileDrawerOverlay open={open} onClose={close} />
      <nav
        ref={drawerRef}
        role="navigation"
        aria-label="Main navigation"
        className={`fixed inset-y-0 right-0 z-50 w-56 bg-background border-l border-border overflow-y-auto transition-transform min-[940px]:hidden ${
          open ? "translate-x-0" : "translate-x-full invisible"
        }`}
      >
        <div className="flex items-center justify-end gap-1 px-4 h-12">
          <ThemeToggle />
          <button
            onClick={close}
            className="w-8 h-8 flex items-center justify-center text-muted hover:text-foreground transition-colors"
            aria-label={tc("closeMenu")}
          >
            <svg
              width="16"
              height="16"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
              aria-hidden="true"
            >
              <path d="M18 6L6 18M6 6l12 12" />
            </svg>
          </button>
        </div>

        <div className="flex flex-col gap-3 text-sm text-muted px-4 pb-4">
          <Link
            href="/docs/getting-started"
            onClick={close}
            className="hover:text-foreground transition-colors py-1"
          >
            {t("docs")}
          </Link>
          <Link
            href="/blog"
            onClick={close}
            className="hover:text-foreground transition-colors py-1"
          >
            {t("blog")}
          </Link>
          <Link
            href="/docs/changelog"
            onClick={close}
            className="hover:text-foreground transition-colors py-1"
          >
            {t("changelog")}
          </Link>
          <Link
            href="/community"
            onClick={close}
            className="hover:text-foreground transition-colors py-1"
          >
            {t("community")}
          </Link>
          <GitHubStarsBadge location="mobile_drawer" />
          <div className="pt-2">
            <DownloadButton size="sm" location="mobile_drawer" />
          </div>
        </div>
      </nav>
    </>
  );
}
