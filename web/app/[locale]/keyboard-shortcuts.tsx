"use client";

import { useMemo, useState } from "react";
import { useTranslations } from "next-intl";

type Shortcut = {
  id: string;
  combos: string[][];
  note?: string;
};

type ShortcutCategory = {
  id: string;
  titleKey: string;
  blurbKey?: string;
  shortcuts: Shortcut[];
};

const CATEGORIES: ShortcutCategory[] = [
  {
    id: "workspaces",
    titleKey: "workspaces",
    blurbKey: "workspacesBlurb",
    shortcuts: [
      { id: "ws-new", combos: [["⌘", "N"]] },
      { id: "ws-prev", combos: [["⌃", "⌘", "["]] },
      { id: "ws-next", combos: [["⌃", "⌘", "]"]] },
      { id: "ws-jump-1-8", combos: [["⌘", "1–8"]] },
      { id: "ws-jump-last", combos: [["⌘", "9"]] },
      { id: "ws-close", combos: [["⌘", "⇧", "W"]] },
      { id: "ws-rename", combos: [["⌘", "⇧", "R"]] },
    ],
  },
  {
    id: "surfaces",
    titleKey: "surfaces",
    blurbKey: "surfacesBlurb",
    shortcuts: [
      { id: "sf-new", combos: [["⌘", "T"]] },
      { id: "sf-prev-1", combos: [["⌘", "⇧", "["]] },
      { id: "sf-prev-2", combos: [["⌃", "⇧", "Tab"]] },
      { id: "sf-jump-1-8", combos: [["⌃", "1–8"]] },
      { id: "sf-jump-last", combos: [["⌃", "9"]] },
      { id: "sf-close", combos: [["⌘", "W"]] },
    ],
  },
  {
    id: "split-panes",
    titleKey: "splitPanes",
    shortcuts: [
      { id: "sp-right", combos: [["⌘", "D"]] },
      { id: "sp-down", combos: [["⌘", "⇧", "D"]] },
      { id: "sp-focus", combos: [["⌥", "⌘", "←/→/↑/↓"]] },
      { id: "sp-browser-right", combos: [["⌥", "⌘", "D"]] },
      { id: "sp-browser-down", combos: [["⌥", "⌘", "⇧", "D"]] },
    ],
  },
  {
    id: "browser",
    titleKey: "browser",
    shortcuts: [
      { id: "br-open", combos: [["⌘", "⇧", "L"]] },
      { id: "br-addr", combos: [["⌘", "L"]] },
      { id: "br-forward", combos: [["⌘", "]"]] },
      { id: "br-reload", combos: [["⌘", "R"]] },
      { id: "br-devtools", combos: [["⌥", "⌘", "I"]] },
    ],
  },
  {
    id: "notifications",
    titleKey: "notifications",
    shortcuts: [
      { id: "nt-panel", combos: [["⌘", "⇧", "I"]] },
      { id: "nt-latest", combos: [["⌘", "⇧", "U"]] },
      { id: "nt-flash", combos: [["⌘", "⇧", "L"]] },
    ],
  },
  {
    id: "find",
    titleKey: "find",
    shortcuts: [
      { id: "fd-find", combos: [["⌘", "F"]] },
      { id: "fd-next-prev", combos: [["⌘", "G"], ["⌘", "⇧", "G"]] },
      { id: "fd-hide", combos: [["⌘", "⇧", "F"]] },
      { id: "fd-selection", combos: [["⌘", "E"]] },
    ],
  },
  {
    id: "terminal",
    titleKey: "terminal",
    shortcuts: [
      { id: "tm-clear", combos: [["⌘", "K"]] },
      { id: "tm-copy", combos: [["⌘", "C"]] },
      { id: "tm-paste", combos: [["⌘", "V"]] },
      { id: "tm-font", combos: [["⌘", "+"], ["⌘", "-"]] },
      { id: "tm-reset", combos: [["⌘", "0"]] },
    ],
  },
  {
    id: "window",
    titleKey: "window",
    shortcuts: [
      { id: "wn-new", combos: [["⌘", "⇧", "N"]] },
      { id: "wn-settings", combos: [["⌘", ","]] },
      { id: "wn-reload", combos: [["⌘", "⇧", "R"]] },
      { id: "wn-quit", combos: [["⌘", "Q"]] },
    ],
  },
];

function normalize(s: string) {
  return s.toLowerCase().replace(/\s+/g, " ").trim();
}

function comboToText(combo: string[]) {
  return combo.join(" ");
}

function KeyCombo({ combo }: { combo: string[] }) {
  return (
    <span className="inline-flex items-center">
      {combo.map((k, idx) => (
        <span key={`${k}-${idx}`} className="inline-flex items-center">
          <kbd>{k}</kbd>
          {idx < combo.length - 1 && (
            <span className="text-muted/30 text-[10px] mx-[3px] select-none font-mono">
              +
            </span>
          )}
        </span>
      ))}
    </span>
  );
}

function ShortcutRow({ shortcut, description, note }: { shortcut: Shortcut; description: string; note?: string }) {
  return (
    <div className="flex items-center justify-between gap-4 py-[11px] px-4 hover:bg-foreground/[0.025] transition-colors">
      <div className="min-w-0">
        <span className="text-[14px] text-foreground/90">
          {description}
        </span>
        {note && (
          <span className="text-[12px] text-muted/50 ml-2">
            {note}
          </span>
        )}
      </div>
      <div className="flex items-center gap-3 shrink-0">
        {shortcut.combos.map((combo, idx) => (
          <span
            key={`${shortcut.id}-combo-${idx}`}
            className="inline-flex items-center"
          >
            {idx > 0 && (
              <span className="text-muted/30 text-[11px] select-none mr-3 font-mono">
                /
              </span>
            )}
            <KeyCombo combo={combo} />
          </span>
        ))}
      </div>
    </div>
  );
}

export function KeyboardShortcuts() {
  const [query, setQuery] = useState("");
  const t = useTranslations("docs.keyboardShortcuts");

  const trimmedQuery = query.trim();

  const filtered = useMemo(() => {
    const q = normalize(query);
    if (!q) return CATEGORIES;
    return CATEGORIES.map((cat) => ({
      ...cat,
      shortcuts: cat.shortcuts.filter((s) => {
        const catTitle = t(`cat.${cat.titleKey}`);
        const desc = t(`sc.${s.id}`);
        const combos = s.combos.map(comboToText).join(" ");
        return normalize(`${catTitle} ${combos} ${desc} ${s.note ?? ""}`).includes(q);
      }),
    })).filter((cat) => cat.shortcuts.length > 0);
  }, [query, t]);

  return (
    <div className="mt-2 mb-12">
      {/* Search */}
      <div className="relative mb-8">
        <div className="pointer-events-none absolute left-2.5 top-1/2 -translate-y-1/2 text-muted/40">
          <svg
            width="14"
            height="14"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <circle cx="11" cy="11" r="8" />
            <path d="M21 21l-4.3-4.3" />
          </svg>
        </div>
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder={t("searchPlaceholder")}
          className="w-full pl-9 pr-3 py-1.5 rounded-lg border border-border bg-transparent text-[13px] placeholder:text-muted/40 focus:outline-none focus:border-foreground/20 transition-colors"
          aria-label={t("searchLabel")}
        />
      </div>

      {/* Category jump links */}
      {!trimmedQuery && (
        <nav className="flex flex-wrap items-center gap-y-2 mb-10">
          {CATEGORIES.map((cat, idx) => (
            <span key={cat.id} className="inline-flex items-center">
              <a
                href={`#${cat.id}`}
                className="text-[13px] text-muted hover:text-foreground transition-colors"
              >
                {t(`cat.${cat.titleKey}`)}
              </a>
              {idx < CATEGORIES.length - 1 && (
                <span className="text-border mx-2.5 text-[10px] select-none">
                  ·
                </span>
              )}
            </span>
          ))}
        </nav>
      )}

      {/* Content */}
      {filtered.length === 0 ? (
        <div className="py-16 text-center">
          <p className="text-[14px] text-muted/70">{t("noResults")}</p>
          <p className="text-[13px] text-muted/40 mt-1.5">
            {t("noResultsHint")}
          </p>
        </div>
      ) : (
        <div className="space-y-10">
          {filtered.map((cat) => (
            <section key={cat.id} id={cat.id} className="scroll-mt-20">
              <div className="mb-3">
                <div className="text-[13px] font-medium text-muted/60">
                  {t(`cat.${cat.titleKey}`)}
                </div>
                {cat.blurbKey && (
                  <p className="text-[13px] text-muted/50 mt-1">{t(`cat.${cat.blurbKey}`)}</p>
                )}
              </div>
              <div className="rounded-xl border border-border overflow-hidden">
                <div className="divide-y divide-border/60">
                  {cat.shortcuts.map((s) => (
                    <ShortcutRow key={s.id} shortcut={s} description={t(`sc.${s.id}`)} />
                  ))}
                </div>
              </div>
            </section>
          ))}
        </div>
      )}
    </div>
  );
}
