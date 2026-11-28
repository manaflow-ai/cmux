"use client";

import { useMatches } from "@tanstack/react-router";
import { useTranslations } from "next-intl";
import type enMessages from "../../messages/en.json";

type DashboardMessages = (typeof enMessages)["dashboard"];

/**
 * A `dashboard.<section>.metaTitle` message key. Only sections that define a
 * `metaTitle` qualify, so a route can never name a missing title.
 */
export type DashboardTitleKey = {
  [Section in keyof DashboardMessages & string]: DashboardMessages[Section] extends { readonly metaTitle: string }
    ? `${Section}.metaTitle`
    : never;
}[keyof DashboardMessages & string];

declare module "@tanstack/react-router" {
  interface StaticDataRouteOption {
    /** Document title for this route. Routes without one keep the site title from the Next layout. */
    readonly titleKey?: DashboardTitleKey;
  }
}

/** The deepest matched route's `staticData.titleKey`, if any. */
export function useDashboardTitleKey(): DashboardTitleKey | undefined {
  return useMatches({
    select: (matches) => matches.reduce<DashboardTitleKey | undefined>(
      (key, match) => match.staticData.titleKey ?? key,
      undefined,
    ),
  });
}

/**
 * Renders the active route's title. React hoists `<title>` into `<head>` ahead
 * of the layout's, and removes it on navigation to an untitled route, which
 * restores the layout title the old Next pages also inherited.
 */
export function DashboardTitle() {
  const t = useTranslations("dashboard");
  const titleKey = useDashboardTitleKey();
  return titleKey ? <title>{t(titleKey)}</title> : null;
}
