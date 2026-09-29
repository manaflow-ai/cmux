"use client";

import { useCallback, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import { usePathname } from "@/i18n/navigation";
import { DocsSidebar } from "@/app/[locale]/components/docs-sidebar";
import { DocsPager } from "@/app/[locale]/components/docs-pager";
import { DocsToc, useDocsHeadings } from "@/app/[locale]/components/docs-toc";
import { DocsPageActions } from "@/app/[locale]/components/docs-page-actions";
import {
  DocsSearchDialog,
  DocsSearchTrigger,
  useDocsSearchShortcut,
} from "@/app/[locale]/components/docs-search-dialog";
import {
  isSection,
  navItemsForLocale,
  type NavEntry,
} from "@/app/[locale]/components/docs-nav-items";
import { docsNavPath } from "@/app/lib/docs-channel";
import {
  useMobileDrawer,
  MobileDrawerOverlay,
} from "@/app/[locale]/components/mobile-drawer";
import { DocsChannelProvider } from "@/app/[locale]/components/docs-channel-context";

/** Header height (h-12) plus its 1px bottom border. */
const HEADER_OFFSET = "top-[49px]";

function currentPage(entries: NavEntry[], path: string) {
  for (const entry of entries) {
    if (!isSection(entry)) {
      if (entry.href === path) return { sectionKey: null, titleKey: entry.titleKey };
      continue;
    }
    const child = entry.children.find((c) => c.href === path);
    if (child) return { sectionKey: entry.sectionKey, titleKey: child.titleKey };
  }
  return null;
}

export function DocsNav({
  children,
  channel,
  footer,
}: {
  children: React.ReactNode;
  channel: "release" | "nightly";
  /** Site footer, rendered in the content column beside the fixed sidebar. */
  footer?: React.ReactNode;
}) {
  const { open, toggle, close, drawerRef, buttonRef } = useMobileDrawer();
  const [searchOpen, setSearchOpen] = useState(false);
  const openSearch = useCallback(() => setSearchOpen(true), []);
  useDocsSearchShortcut(openSearch);
  const { contentRef, headings, activeId, setActiveId } = useDocsHeadings();

  const locale = useLocale();
  const pathname = usePathname();
  const t = useTranslations("docs.navItems");
  const tu = useTranslations("docs.ui");
  // Changelog version pages have no nav entry; label them by the changelog.
  const navPath = docsNavPath(pathname, locale).replace(/^\/docs\/changelog\/.+$/, "/docs/changelog");
  const page = currentPage(navItemsForLocale(locale, channel), navPath);
  const eyebrow = page?.sectionKey ? t(page.sectionKey) : null;

  return (
    <DocsChannelProvider value={channel}>
      <DocsSearchDialog open={searchOpen} onOpenChange={setSearchOpen} />

      {/* Mobile bar: menu, breadcrumb, search */}
      <div
        className={`sticky ${HEADER_OFFSET} z-20 flex h-11 items-center gap-3 border-b border-border/70 bg-background/90 px-4 backdrop-blur lg:hidden`}
        data-pagefind-ignore="all"
      >
        <button
          ref={buttonRef}
          onClick={toggle}
          aria-expanded={open}
          aria-controls="docs-sidebar"
          aria-label={open ? tu("closeNavigation") : tu("openNavigation")}
          className="flex h-8 w-8 items-center justify-center rounded-lg text-muted transition-colors hover:bg-code-bg hover:text-foreground"
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <path d="M3 6h18M3 12h18M3 18h18" />
          </svg>
        </button>
        <div className="flex min-w-0 flex-1 items-center gap-1.5 text-[13px]">
          {eyebrow && (
            <>
              <span className="truncate text-muted">{eyebrow}</span>
              <span className="text-muted" aria-hidden>›</span>
            </>
          )}
          {page && <span className="truncate font-medium text-foreground">{t(page.titleKey)}</span>}
        </div>
        <DocsSearchTrigger onOpen={openSearch} compact />
      </div>

      <MobileDrawerOverlay open={open} onClose={close} />

      {/* Sidebar: fixed to the left edge from the header to the window bottom */}
      <aside
        ref={drawerRef}
        id="docs-sidebar"
        role="navigation"
        aria-label="Documentation"
        data-pagefind-ignore="all"
        className={`fixed bottom-0 left-0 top-0 z-50 w-[16.5rem] overflow-y-auto overscroll-contain border-r border-border bg-background px-5 pb-8 pt-5 transition-transform lg:top-[49px] lg:z-20 lg:translate-x-0 lg:border-r-0 ${
          open ? "translate-x-0" : "-translate-x-full"
        }`}
      >
        <DocsSidebar onNavigate={close} onOpenSearch={openSearch} channel={channel} />
      </aside>

      <div className="flex w-full lg:pl-[16.5rem]">
        {/* Content */}
        <main className="min-w-0 flex-1">
          <div className="mx-auto w-full max-w-5xl px-6 pb-16 pt-8 lg:max-w-4xl lg:px-8 lg:pt-10">
            <div className="relative" data-pagefind-ignore="all">
              <div className="mb-2.5 h-5 truncate text-[14px] font-medium leading-5 text-muted">
                {eyebrow}
              </div>
              {/* Sits on the title line, like Mintlify; the title reserves room for it. */}
              <div className="absolute right-0 top-[33px] z-10 hidden sm:block">
                <DocsPageActions />
              </div>
            </div>
            <div
              ref={contentRef}
              className="docs-content text-[15px]"
              data-docs-page-body
              data-pagefind-body
              data-pagefind-meta="section:Docs"
            >
              {children}
            </div>
            <div data-pagefind-ignore="all">
              <DocsPager />
            </div>
          </div>
          {footer && (
            <div className="border-t border-border/70" data-pagefind-ignore="all">
              {footer}
            </div>
          )}
        </main>

        {/* On this page: pinned to the right edge */}
        <aside className="hidden w-[15.5rem] shrink-0 pr-6 xl:block" data-pagefind-ignore="all">
          <div className="sticky top-[49px] max-h-[calc(100dvh-49px)] overflow-y-auto pb-10 pl-2 pt-10">
            <DocsToc headings={headings} activeId={activeId} onSelect={setActiveId} />
          </div>
        </aside>
      </div>
    </DocsChannelProvider>
  );
}
