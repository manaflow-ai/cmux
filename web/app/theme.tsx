"use client";

import { useTheme } from "next-themes";
import { useSyncExternalStore } from "react";
import { flushSync } from "react-dom";

const subscribe = () => () => {};
const getSnapshot = () => true;
const getServerSnapshot = () => false;

export function ThemeToggle() {
  const { resolvedTheme, setTheme } = useTheme();
  const mounted = useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);

  const toggle = () => {
    const next = resolvedTheme === "dark" ? "light" : "dark";

    if (
      !document.startViewTransition ||
      window.matchMedia("(prefers-reduced-motion: reduce)").matches
    ) {
      setTheme(next);
      return;
    }

    document.startViewTransition(() => {
      flushSync(() => {
        setTheme(next);
      });
    });
  };

  const isDark = mounted ? resolvedTheme === "dark" : true;

  return (
    <button
      onClick={toggle}
      className="inline-flex h-9 w-9 items-center justify-center text-muted hover:text-foreground transition-colors cursor-pointer"
      aria-label={isDark ? "Switch to light mode" : "Switch to dark mode"}
    >
      <ThemeIcon mounted={mounted} isDark={isDark} />
    </button>
  );
}

// Render a stable SVG subtree so theme flips don't unmount/mount icon nodes.
export function ThemeIcon({ mounted, isDark }: { mounted: boolean; isDark: boolean }) {
  const base = "transition-opacity";
  const shown = "opacity-100";
  const hidden = "opacity-0";

  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={mounted ? shown : hidden}
    >
      <g data-icon="sun" className={`${base} ${isDark ? shown : hidden}`}>
        <circle cx="12" cy="12" r="5" />
        <line x1="12" y1="1" x2="12" y2="3" />
        <line x1="12" y1="21" x2="12" y2="23" />
        <line x1="4.22" y1="4.22" x2="5.64" y2="5.64" />
        <line x1="18.36" y1="18.36" x2="19.78" y2="19.78" />
        <line x1="1" y1="12" x2="3" y2="12" />
        <line x1="21" y1="12" x2="23" y2="12" />
        <line x1="4.22" y1="19.78" x2="5.64" y2="18.36" />
        <line x1="18.36" y1="5.64" x2="19.78" y2="4.22" />
      </g>
      <g data-icon="moon" className={`${base} ${isDark ? hidden : shown}`}>
        <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
      </g>
    </svg>
  );
}
