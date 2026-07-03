import type { Locale } from "./routing";

export const featureWorkflowContentLocales = [
  "en",
  "ja",
] as const satisfies readonly Locale[];

export const remoteTmuxDocsLocales = [
  "en",
  "ja",
] as const satisfies readonly Locale[];

export function hasFeatureWorkflowContent(
  locale: string,
): locale is (typeof featureWorkflowContentLocales)[number] {
  return featureWorkflowContentLocales.includes(
    locale as (typeof featureWorkflowContentLocales)[number],
  );
}
