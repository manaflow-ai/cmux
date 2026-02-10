"use client";

import { useState, useEffect, useRef, useCallback } from "react";

export function useMobileDrawer() {
  const [open, setOpen] = useState(false);
  const drawerRef = useRef<HTMLElement>(null);
  const buttonRef = useRef<HTMLButtonElement>(null);

  const close = useCallback(() => {
    setOpen(false);
    buttonRef.current?.focus();
  }, []);

  const toggle = useCallback(() => setOpen((v) => !v), []);

  // Close on Escape
  useEffect(() => {
    if (!open) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") close();
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [open, close]);

  // Trap focus
  useEffect(() => {
    if (!open || !drawerRef.current) return;
    const el = drawerRef.current;
    const focusable = el.querySelectorAll<HTMLElement>(
      'a[href], button, [tabindex]:not([tabindex="-1"])'
    );
    if (focusable.length === 0) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
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
    el.addEventListener("keydown", trap);
    return () => el.removeEventListener("keydown", trap);
  }, [open]);

  // Lock body scroll on mobile
  useEffect(() => {
    if (!open) return;
    const mq = window.matchMedia("(min-width: 768px)");
    if (mq.matches) return;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = "";
    };
  }, [open]);

  return { open, setOpen, toggle, close, drawerRef, buttonRef };
}

export function MobileDrawerOverlay({ open, onClose }: { open: boolean; onClose: () => void }) {
  if (!open) return null;
  return (
    <div
      className="fixed top-12 left-0 right-0 bottom-0 z-30 bg-black/50 md:hidden"
      aria-hidden="true"
      onClick={onClose}
    />
  );
}

/** Hamburger / X toggle button (only visible on mobile) */
export function MobileDrawerToggle({
  open,
  onClick,
  buttonRef,
  className,
}: {
  open: boolean;
  onClick: () => void;
  buttonRef: React.RefObject<HTMLButtonElement | null>;
  className?: string;
}) {
  return (
    <button
      ref={buttonRef}
      onClick={onClick}
      aria-expanded={open}
      className={
        className ??
        "md:hidden w-8 h-8 flex items-center justify-center text-muted hover:text-foreground transition-colors"
      }
      aria-label={open ? "Close menu" : "Open menu"}
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
  );
}
