"use client";

import { useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import posthog from "posthog-js";
import { usePathname } from "../../../i18n/navigation";
import {
  navItemsForLocale,
  flatNavItems,
  type NavLink,
} from "./docs-nav-items";
import { ContentLocaleLink } from "./content-locale-link";
import { docsChannelUrl, docsNavPath } from "@/app/lib/docs-channel";
import { docsPagerAdjacentItems } from "@/app/lib/docs-pager-path";
import { useDocsChannel } from "./docs-channel-context";

const thumbPath =
  "M7 10v12M15 5.88 14 10h5.83a2 2 0 0 1 1.92 2.56l-2.33 8A2 2 0 0 1 17.5 22H4a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h2.76a2 2 0 0 0 1.79-1.11L12 2a3.13 3.13 0 0 1 3 3.88Z";

function Thumb({ down }: { down?: boolean }) {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      style={down ? { transform: "scale(1, -1)" } : undefined}
    >
      <path d={thumbPath} />
    </svg>
  );
}

/** "Was this page helpful?" with a GitHub issue link, keyed by page path. */
function DocsFeedback({ pathname }: { pathname: string }) {
  const t = useTranslations("docs.ui");
  // Remember the answer per page so client navigation resets the prompt.
  const [answered, setAnswered] = useState<string | null>(null);
  const done = answered === pathname;

  function answer(helpful: boolean) {
    posthog.capture("cmuxterm_docs_feedback", { helpful, path: pathname });
    setAnswered(pathname);
  }

  const issueUrl = `https://github.com/manaflow-ai/cmux/issues/new?title=${encodeURIComponent(
    `Docs: ${pathname}`,
  )}&labels=documentation`;
  const buttonClass =
    "flex items-center gap-1.5 rounded-lg border border-border px-2.5 py-1 text-[13px] text-muted transition-colors hover:border-muted/50 hover:text-foreground";

  return (
    <div className="flex flex-wrap items-center justify-between gap-3 text-[13px] text-muted">
      {done ? (
        <span>{t("thanks")}</span>
      ) : (
        <div className="flex items-center gap-3">
          <span>{t("helpful")}</span>
          <div className="flex gap-2">
            <button type="button" className={buttonClass} onClick={() => answer(true)}>
              <Thumb />
              {t("yes")}
            </button>
            <button type="button" className={buttonClass} onClick={() => answer(false)}>
              <Thumb down />
              {t("no")}
            </button>
          </div>
        </div>
      )}
      <a
        href={issueUrl}
        target="_blank"
        rel="noopener noreferrer"
        className="flex items-center gap-1.5 transition-colors hover:text-foreground"
      >
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <circle cx="12" cy="12" r="10" />
          <path d="M12 8v4M12 16h.01" />
        </svg>
        {t("raiseIssue")}
      </a>
    </div>
  );
}

function PagerCard({
  item,
  direction,
}: {
  item: NavLink;
  direction: "previous" | "next";
}) {
  const locale = useLocale();
  const channel = useDocsChannel();
  const t = useTranslations("docs.navItems");
  const tu = useTranslations("docs.ui");
  const next = direction === "next";

  return (
    <ContentLocaleLink
      href={docsChannelUrl(channel, item.href)}
      currentLocale={locale}
      contentLocales={item.contentLocales}
      className={`group flex flex-1 flex-col gap-1 rounded-2xl border border-border px-4 py-3 transition-colors hover:border-docs-primary/50 ${
        next ? "items-end text-right" : "items-start"
      }`}
    >
      <span className="text-[12px] text-muted">{tu(direction)}</span>
      <span className="flex items-center gap-1.5 text-[14px] font-medium text-foreground group-hover:text-docs-primary">
        {!next && <span aria-hidden>&larr;</span>}
        {t(item.titleKey)}
        {next && <span aria-hidden>&rarr;</span>}
      </span>
    </ContentLocaleLink>
  );
}

export function DocsPager() {
  const pathname = usePathname();
  const locale = useLocale();
  const channel = useDocsChannel();
  const flat = flatNavItems(navItemsForLocale(locale, channel));
  const releasePathname = docsNavPath(pathname, locale);
  const { prev, next } = docsPagerAdjacentItems(flat, releasePathname);

  return (
    <div className="mt-14 space-y-8">
      <DocsFeedback pathname={releasePathname} />
      {(prev || next) && (
        <nav className="flex flex-col gap-3 sm:flex-row">
          {prev ? <PagerCard item={prev} direction="previous" /> : <span className="hidden flex-1 sm:block" />}
          {next ? <PagerCard item={next} direction="next" /> : <span className="hidden flex-1 sm:block" />}
        </nav>
      )}
    </div>
  );
}
