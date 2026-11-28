"use client";

import { useCallback, useState } from "react";
import { useTranslations } from "next-intl";

export type DocsTocHeading = { id: string; text: string; level: 2 | 3 };

/** Sticky header (49px) plus breathing room: a heading above this line is "read". */
const ACTIVE_OFFSET_PX = 120;

function readHeadings(root: HTMLElement): DocsTocHeading[] {
  return Array.from(
    root.querySelectorAll<HTMLHeadingElement>("h2[id], h3[id]"),
  ).flatMap((heading) => {
    // Client navigation keeps earlier pages mounted but hidden; skip them.
    // checkVisibility needs Safari 17.4+; a hidden subtree has no client rects.
    const visible =
      typeof heading.checkVisibility === "function"
        ? heading.checkVisibility()
        : heading.getClientRects().length > 0;
    if (!visible) return [];
    // The anchor link inside each heading is an icon, not heading text.
    const clone = heading.cloneNode(true) as HTMLElement;
    clone.querySelectorAll("[data-pagefind-ignore]").forEach((n) => n.remove());
    const text = clone.textContent?.trim();
    if (!text) return [];
    return [{ id: heading.id, text, level: heading.tagName === "H2" ? 2 : 3 }];
  });
}

function sameHeadings(a: DocsTocHeading[], b: DocsTocHeading[]) {
  return a.length === b.length && a.every((h, i) => h.id === b[i].id && h.text === b[i].text);
}

/**
 * Tracks the h2/h3 headings inside the docs content element and which one the
 * reader is on. Attach `contentRef` to the element that holds the page body;
 * it re-reads headings when client navigation swaps the page.
 */
export function useDocsHeadings() {
  const [headings, setHeadings] = useState<DocsTocHeading[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);

  const contentRef = useCallback((root: HTMLElement | null) => {
    if (!root) return;
    let current: DocsTocHeading[] = [];
    let frame = 0;

    // The active heading is the last one whose top has passed the sticky
    // header band. At the bottom of the page the last heading wins, because
    // a short final section can never reach the band.
    const updateActive = () => {
      frame = 0;
      if (current.length === 0) return;
      const atBottom =
        window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4;
      let active = current[0].id;
      for (const heading of current) {
        const el = document.getElementById(heading.id);
        if (el && el.getBoundingClientRect().top <= ACTIVE_OFFSET_PX) active = heading.id;
      }
      if (atBottom) active = current[current.length - 1].id;
      setActiveId(active);
    };
    const schedule = () => {
      if (!frame) frame = window.requestAnimationFrame(updateActive);
    };
    const readAll = () => {
      const next = readHeadings(root);
      current = next;
      setHeadings((prev) => (sameHeadings(prev, next) ? prev : next));
      schedule();
    };

    readAll();
    const mutations = new MutationObserver(readAll);
    mutations.observe(root, { childList: true, subtree: true, characterData: true });
    window.addEventListener("scroll", schedule, { passive: true });
    window.addEventListener("resize", schedule);
    return () => {
      mutations.disconnect();
      window.removeEventListener("scroll", schedule);
      window.removeEventListener("resize", schedule);
      if (frame) window.cancelAnimationFrame(frame);
    };
  }, []);

  return { contentRef, headings, activeId, setActiveId };
}

export function DocsToc({
  headings,
  activeId,
  onSelect,
}: {
  headings: DocsTocHeading[];
  activeId: string | null;
  onSelect: (id: string) => void;
}) {
  const t = useTranslations("docs.ui");
  if (headings.length === 0) return null;

  return (
    <nav aria-label={t("onThisPage")} data-pagefind-ignore="all" className="text-[14px] leading-6">
      <div className="mb-3 flex items-center gap-2 font-medium text-foreground">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <path d="M3 6h18M3 12h12M3 18h15" />
        </svg>
        {t("onThisPage")}
      </div>
      <ul className="border-l border-border">
        {headings.map((heading) => {
          const active = heading.id === activeId;
          return (
            <li key={heading.id}>
              <a
                href={`#${heading.id}`}
                onClick={() => onSelect(heading.id)}
                aria-current={active ? "location" : undefined}
                className={`-ml-px block border-l py-1 transition-colors ${
                  heading.level === 3 ? "pl-7" : "pl-4"
                } ${
                  active
                    ? "border-foreground font-medium text-foreground"
                    : "border-transparent text-muted hover:border-muted/50 hover:text-foreground"
                }`}
              >
                {heading.text}
              </a>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
