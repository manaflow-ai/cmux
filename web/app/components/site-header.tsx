"use client";

import Link from "next/link";
import posthog from "posthog-js";
import { NavLinks } from "./nav-links";
import { DownloadButton } from "./download-button";
import { ThemeToggle } from "../theme";
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
  const { open, toggle, close, drawerRef, buttonRef } = useMobileDrawer();

  return (
    <>
      <header className="sticky top-0 z-30 w-full bg-background">
        <div className="w-full max-w-6xl mx-auto flex items-center px-6 h-12">
          {/* Left: logo + section */}
          <div className="flex flex-1 items-center gap-3 min-w-0">
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
          <nav className="hidden md:flex items-center justify-center gap-4 text-sm text-muted shrink-0">
            <NavLinks />
          </nav>

          {/* Right: Download + theme + mobile */}
          <div className="flex flex-1 items-center justify-end gap-1 min-w-0">
            <div className="hidden md:block">
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

      {/* Mobile overlay + drawer — outside header to avoid backdrop-filter breaking fixed positioning on iOS */}
      <MobileDrawerOverlay open={open} onClose={close} />
      <nav
        ref={drawerRef}
        role="navigation"
        aria-label="Main navigation"
        className={`fixed inset-y-0 right-0 z-50 w-56 bg-background border-l border-border overflow-y-auto transition-transform md:hidden ${
          open ? "translate-x-0" : "translate-x-full invisible"
        }`}
      >
        {/* Drawer header — mirrors the site header row */}
        <div className="flex items-center justify-end gap-1 px-4 h-12">
          <ThemeToggle />
          <button
            onClick={close}
            className="w-8 h-8 flex items-center justify-center text-muted hover:text-foreground transition-colors"
            aria-label="Close menu"
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
            Docs
          </Link>
          <Link
            href="/blog"
            onClick={close}
            className="hover:text-foreground transition-colors py-1"
          >
            Blog
          </Link>
          <Link
            href="/docs/changelog"
            onClick={close}
            className="hover:text-foreground transition-colors py-1"
          >
            Changelog
          </Link>
          <Link
            href="/community"
            onClick={close}
            className="hover:text-foreground transition-colors py-1"
          >
            Community
          </Link>
          <a
            href="https://github.com/manaflow-ai/cmux"
            target="_blank"
            rel="noopener noreferrer"
            onClick={() => posthog.capture("cmuxterm_github_clicked", { location: "mobile_drawer" })}
            className="hover:text-foreground transition-colors py-1"
          >
            GitHub
          </a>
          <div className="pt-2">
            <DownloadButton size="sm" location="mobile_drawer" />
          </div>
        </div>
      </nav>
    </>
  );
}
