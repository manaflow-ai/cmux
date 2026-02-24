"use client";

import { DocsSidebar } from "../components/docs-sidebar";
import { DocsPager } from "../components/docs-pager";
import {
  useMobileDrawer,
  MobileDrawerOverlay,
} from "../components/mobile-drawer";

export function DocsNav({ children }: { children: React.ReactNode }) {
  const { open, toggle, close, drawerRef, buttonRef } = useMobileDrawer();

  return (
    <div className="max-w-6xl mx-auto flex px-0 md:px-4">
      {/* Mobile menu button */}
      <button
        ref={buttonRef}
        onClick={toggle}
        aria-expanded={open}
        aria-controls="docs-sidebar"
        className="fixed bottom-4 right-4 z-50 md:hidden w-10 h-10 rounded-full bg-foreground text-background flex items-center justify-center shadow-lg"
        aria-label={open ? "Close navigation" : "Open navigation"}
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
          {open ? (
            <path d="M18 6L6 18M6 6l12 12" />
          ) : (
            <>
              <path d="M3 6h18" />
              <path d="M3 12h18" />
              <path d="M3 18h18" />
            </>
          )}
        </svg>
      </button>

      {/* Mobile overlay */}
      <MobileDrawerOverlay open={open} onClose={close} />

      {/* Sidebar */}
      <aside
        ref={drawerRef}
        id="docs-sidebar"
        role="navigation"
        aria-label="Documentation"
        style={{ height: "calc(100dvh - 3rem)" }}
        className={`fixed top-12 left-0 z-50 w-56 bg-background py-4 pr-4 overflow-y-auto transition-transform md:sticky md:top-12 md:z-20 md:shrink-0 md:translate-x-0 ${
          open ? "translate-x-0" : "-translate-x-full"
        }`}
      >
        <DocsSidebar onNavigate={close} />
      </aside>

      {/* Content */}
      <main className="flex-1 min-w-0 overflow-x-hidden">
        <div className="max-w-full px-6 pb-10 ml-0" data-dev="docs-content" style={{ paddingTop: 16 }}>
          <div className="docs-content text-[15px]">{children}</div>
          <DocsPager />
        </div>
      </main>
    </div>
  );
}
