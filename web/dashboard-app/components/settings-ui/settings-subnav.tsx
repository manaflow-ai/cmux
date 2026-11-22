"use client";

import { useRef, type ReactNode } from "react";
import { Link, type LinkOptions } from "@tanstack/react-router";
import { ChevronDownIcon } from "./icons";

export type SettingsSubnavItem = {
  /** Typed router target; `activeOptions` should agree with `active`. */
  readonly link: LinkOptions;
  readonly label: ReactNode;
  readonly active: boolean;
  /** Stable key; defaults to the link target. */
  readonly id?: string;
  /** Leading visual such as a team avatar. */
  readonly icon?: ReactNode;
};

export type SettingsSubnavGroup = {
  readonly id: string;
  readonly label?: string;
  readonly items: readonly SettingsSubnavItem[];
};

/**
 * Two-column frame for a settings area: navigation beside the content on
 * wide screens, above it on narrow screens. Pass a `<SettingsSubnav />` (or
 * a Suspense boundary around one) as `nav`, so the content never remounts
 * when the navigation finishes loading.
 */
export function SettingsSubnavLayout({
  nav,
  children,
  testId,
}: {
  readonly nav: ReactNode;
  readonly children: ReactNode;
  readonly testId?: string;
}) {
  return (
    <div data-testid={testId} className="mx-auto w-full max-w-5xl px-3 py-4 md:grid md:grid-cols-[12rem_minmax(0,1fr)] md:gap-6">
      <div>{nav}</div>
      <div className="min-w-0">{children}</div>
    </div>
  );
}

/**
 * Secondary navigation for a settings area.
 *
 * Wide screens get a sticky vertical list. Narrow screens get a disclosure
 * whose summary names the current page; opening it shows the full list and
 * picking an entry closes it (list/detail navigation in one control).
 */
export function SettingsSubnav({
  title,
  groups,
}: {
  readonly title: string;
  readonly groups: readonly SettingsSubnavGroup[];
}) {
  const detailsRef = useRef<HTMLDetailsElement>(null);
  const current = groups.flatMap((group) => group.items).find((item) => item.active);
  const close = () => {
    if (detailsRef.current) detailsRef.current.open = false;
  };

  return (
    <>
      <aside className="hidden md:block">
        <div className="sticky top-4">
          <p className="px-2 pb-2 text-xs font-medium text-muted">{title}</p>
          <SubnavList groups={groups} />
        </div>
      </aside>
      <details ref={detailsRef} className="group mb-4 border border-border md:hidden">
        <summary className="flex cursor-pointer list-none items-center justify-between px-3 py-2 [&::-webkit-details-marker]:hidden">
          <span className="min-w-0 truncate">
            <span className="text-muted">{title}</span>
            {current ? <span className="font-medium"> / {current.label}</span> : null}
          </span>
          <span className="transition-transform group-open:rotate-180">
            <ChevronDownIcon />
          </span>
        </summary>
        <div className="border-t border-border p-2">
          <SubnavList groups={groups} onNavigate={close} />
        </div>
      </details>
    </>
  );
}

function SubnavList({
  groups,
  onNavigate,
}: {
  readonly groups: readonly SettingsSubnavGroup[];
  readonly onNavigate?: () => void;
}) {
  return (
    <nav className="space-y-4">
      {groups.map((group) => (
        <div key={group.id}>
          {group.label ? (
            <p className="px-2 pb-1 text-[11px] font-semibold text-foreground">{group.label}</p>
          ) : null}
          <div className="space-y-0.5">
            {group.items.map((item) => (
              <Link
                key={item.id ?? String(item.link.to)}
                {...item.link}
                onClick={onNavigate}
                aria-current={item.active ? "page" : undefined}
                className={`flex min-w-0 items-center gap-2 border-l px-2 py-1.5 focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground ${
                  item.active
                    ? "border-foreground bg-code-bg text-foreground"
                    : "border-transparent text-muted hover:border-border hover:text-foreground"
                }`}
              >
                {item.icon ? <span className="shrink-0">{item.icon}</span> : null}
                <span className="min-w-0 truncate">{item.label}</span>
              </Link>
            ))}
          </div>
        </div>
      ))}
    </nav>
  );
}
