"use client";

import { useState, useEffect, useRef, useCallback } from "react";
import { DocsSidebar } from "../components/docs-sidebar";
import { DocsPager } from "../components/docs-pager";

export function DocsNav({ children }: { children: React.ReactNode }) {
  const [open, setOpen] = useState(false);
  const sidebarRef = useRef<HTMLElement>(null);
  const buttonRef = useRef<HTMLButtonElement>(null);

  const close = useCallback(() => {
    setOpen(false);
    buttonRef.current?.focus();
  }, []);

  // Close on Escape
  useEffect(() => {
    if (!open) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") close();
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [open, close]);

  // Trap focus inside sidebar when open on mobile
  useEffect(() => {
    if (!open || !sidebarRef.current) return;

    const sidebar = sidebarRef.current;
    const focusable = sidebar.querySelectorAll<HTMLElement>(
      'a[href], button, [tabindex]:not([tabindex="-1"])'
    );
    if (focusable.length === 0) return;

    const first = focusable[0];
    const last = focusable[focusable.length - 1];

    // Focus first link
    first.focus();

    const trap = (e: KeyboardEvent) => {
      if (e.key !== "Tab") return;
      if (e.shiftKey) {
        if (document.activeElement === first) {
          e.preventDefault();
          last.focus();
        }
      } else {
        if (document.activeElement === last) {
          e.preventDefault();
          first.focus();
        }
      }
    };

    sidebar.addEventListener("keydown", trap);
    return () => sidebar.removeEventListener("keydown", trap);
  }, [open]);

  // Lock body scroll when open on mobile
  useEffect(() => {
    if (!open) return;
    const mq = window.matchMedia("(min-width: 768px)");
    if (mq.matches) return; // don't lock on desktop
    document.body.style.overflow = "hidden";
    return () => { document.body.style.overflow = ""; };
  }, [open]);

  return (
    <div className="max-w-5xl mx-auto flex px-4">
      {/* Mobile menu button */}
      <button
        ref={buttonRef}
        onClick={() => setOpen(!open)}
        aria-expanded={open}
        aria-controls="docs-sidebar"
        className="fixed bottom-4 right-4 z-40 md:hidden w-10 h-10 rounded-full bg-foreground text-background flex items-center justify-center shadow-lg"
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
      {open && (
        <div
          className="fixed inset-0 z-30 bg-black/50 md:hidden"
          aria-hidden="true"
          onClick={close}
        />
      )}

      {/* Sidebar */}
      <aside
        ref={sidebarRef}
        id="docs-sidebar"
        role="navigation"
        aria-label="Documentation"
        style={{ height: "calc(100dvh - 3rem)" }}
        className={`fixed top-12 left-0 z-40 w-56 bg-background py-4 pr-4 overflow-y-auto transition-transform md:sticky md:top-12 md:z-20 md:shrink-0 md:translate-x-0 ${
          open ? "translate-x-0" : "-translate-x-full"
        }`}
      >
        <DocsSidebar onNavigate={close} />
      </aside>

      {/* Content */}
      <main className="flex-1 min-w-0">
        <div className="max-w-2xl px-6 pb-10 ml-0" data-dev="docs-content" style={{ paddingTop: 8 }}>
          <div className="docs-content text-[15px]">{children}</div>
          <DocsPager />
        </div>
      </main>
    </div>
  );
}
