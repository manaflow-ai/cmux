"use client";

import Image from "next/image";
import Link from "next/link";
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
      <header className="sticky top-0 z-30 w-full bg-background/80 backdrop-blur-sm">
        <div className="w-full max-w-5xl mx-auto flex items-center justify-between px-6 h-12">
          <div className="flex items-center gap-3">
            {!hideLogo && (
              <>
                <Link href="/" className="flex items-center gap-2.5">
                  <Image
                    src="/icon.png"
                    alt="cmux"
                    width={24}
                    height={24}
                    className="rounded-md"
                    unoptimized
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

          <div className="flex items-center gap-1">
            {/* Desktop nav */}
            <nav className="hidden md:flex items-center gap-4 text-sm text-muted">
              <NavLinks />
            </nav>

            <ThemeToggle />

            {/* Mobile hamburger */}
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
        className={`fixed top-12 right-0 z-40 w-56 bg-background border-l border-border py-4 px-4 overflow-y-auto transition-transform md:hidden ${
          open ? "translate-x-0" : "translate-x-full invisible"
        }`}
        style={{ height: "calc(100dvh - 3rem)" }}
      >
        <div className="flex flex-col gap-3 text-sm text-muted">
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
            className="hover:text-foreground transition-colors py-1"
          >
            GitHub
          </a>
          <div className="pt-2">
            <DownloadButton size="sm" />
          </div>
        </div>
      </nav>
    </>
  );
}
