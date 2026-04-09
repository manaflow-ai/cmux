"use client";

import { useMemo, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import { shortcutCategories, type LocalizedText, type Shortcut } from "../../data/cmux-shortcuts";

function localizedText(text: LocalizedText, locale: string) {
  return locale.startsWith("ja") ? text.ja : text.en;
}

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
            <span className="text-muted/30 mx-[3px] select-none font-mono text-[10px]">
              +
            </span>
          )}
        </span>
      ))}
    </span>
  );
}

function ShortcutRow({ shortcut, locale }: { shortcut: Shortcut; locale: string }) {
  const description = localizedText(shortcut.description, locale);
  const note = shortcut.note ? localizedText(shortcut.note, locale) : undefined;

  return (
    <div className="flex items-center justify-between gap-4 px-4 py-[11px] transition-colors hover:bg-foreground/[0.025]">
      <div className="min-w-0">
        <span className="text-[14px] text-foreground/90">{description}</span>
        {note && <span className="ml-2 text-[12px] text-muted/50">{note}</span>}
      </div>
      <div className="flex shrink-0 items-center gap-3">
        {shortcut.combos.map((combo, idx) => (
          <span key={`${shortcut.id}-combo-${idx}`} className="inline-flex items-center">
            {idx > 0 && (
              <span className="mr-3 select-none font-mono text-[11px] text-muted/30">
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
  const locale = useLocale();
  const t = useTranslations("docs.keyboardShortcuts");

  const trimmedQuery = query.trim();

  const filtered = useMemo(() => {
    const q = normalize(query);
    if (!q) return shortcutCategories;
    return shortcutCategories.map((cat) => ({
      ...cat,
      shortcuts: cat.shortcuts.filter((shortcut) => {
        const catTitle = t(`cat.${cat.titleKey}`);
        const description = localizedText(shortcut.description, locale);
        const note = shortcut.note ? localizedText(shortcut.note, locale) : "";
        const combos = shortcut.combos.map(comboToText).join(" ");
        return normalize(`${catTitle} ${combos} ${description} ${note}`).includes(q);
      }),
    })).filter((cat) => cat.shortcuts.length > 0);
  }, [locale, query, t]);

  return (
    <div className="mb-12 mt-2">
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
          className="w-full rounded-lg border border-border bg-transparent py-1.5 pl-9 pr-3 text-[13px] transition-colors placeholder:text-muted/40 focus:border-foreground/20 focus:outline-none"
          aria-label={t("searchLabel")}
        />
      </div>

      {!trimmedQuery && (
        <nav className="mb-10 flex flex-wrap items-center gap-y-2">
          {shortcutCategories.map((cat, idx) => (
            <span key={cat.id} className="inline-flex items-center">
              <a
                href={`#${cat.id}`}
                className="text-[13px] text-muted transition-colors hover:text-foreground"
              >
                {t(`cat.${cat.titleKey}`)}
              </a>
              {idx < shortcutCategories.length - 1 && (
                <span className="mx-2.5 select-none text-[10px] text-border">
                  ·
                </span>
              )}
            </span>
          ))}
        </nav>
      )}

      {filtered.length === 0 ? (
        <div className="py-16 text-center">
          <p className="text-[14px] text-muted/70">{t("noResults")}</p>
          <p className="mt-1.5 text-[13px] text-muted/40">{t("noResultsHint")}</p>
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
                  <p className="mt-1 text-[13px] text-muted/50">{t(`cat.${cat.blurbKey}`)}</p>
                )}
              </div>
              <div className="overflow-hidden rounded-xl border border-border">
                <div className="divide-y divide-border/60">
                  {cat.shortcuts.map((shortcut) => (
                    <ShortcutRow key={shortcut.id} shortcut={shortcut} locale={locale} />
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
