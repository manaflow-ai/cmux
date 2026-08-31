import type { Metadata } from "next";
import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import {
  jobsContentLocales,
  hasFallbackContent,
} from "@/i18n/locale-availability";
import {
  buildAlternates,
  openGraphDefaults,
  seoDescription,
  twitterSummary,
} from "@/i18n/seo";

export type JobRoleNamespace = "jobs" | "jobs.foundingDesigner";

const focusRingClass =
  "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-foreground";
const applicationEmail = "founders@cmux.com";

export async function jobsMetadata({
  params,
  path,
}: {
  params: Promise<{ locale: string }>;
  path: string;
}): Promise<Metadata> {
  const { locale } = await params;
  const contentLocale = hasFallbackContent(locale, jobsContentLocales)
    ? locale
    : "en";
  const t = await getTranslations({ locale: contentLocale, namespace: "jobs" });

  return buildJobMetadata({
    contentLocale,
    path,
    title: `${t("title")} / ${t("foundingDesigner.title")} — ${t("section")}`,
    description: `${t("tagline")} ${t("intro")}`,
  });
}

export async function jobRoleMetadata({
  params,
  path,
  namespace,
}: {
  params: Promise<{ locale: string }>;
  path: string;
  namespace: JobRoleNamespace;
}): Promise<Metadata> {
  const { locale } = await params;
  const contentLocale = hasFallbackContent(locale, jobsContentLocales)
    ? locale
    : "en";
  const t = await getTranslations({ locale: contentLocale, namespace });

  return buildJobMetadata({
    contentLocale,
    path,
    title: t("metaTitle"),
    description: t("metaDescription"),
  });
}

function buildJobMetadata({
  contentLocale,
  path,
  title,
  description: authoredDescription,
}: {
  contentLocale: string;
  path: string;
  title: string;
  description: string;
}): Metadata {
  const description = seoDescription(contentLocale, authoredDescription, {
    minLength: 110,
    appendLocalizedContext: false,
  });
  const alternates = buildAlternates(contentLocale, path, jobsContentLocales);

  return {
    title: { absolute: title },
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(contentLocale, "website"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(contentLocale, title, description),
  };
}

export function JobsPageContent() {
  const t = useTranslations("jobs");

  return (
    <div className="min-h-screen">
      <SiteHeader section={t("section")} />

      <main
        aria-labelledby="jobs-title"
        className="mx-auto w-full max-w-6xl px-6 py-14 sm:py-20"
      >
        <header className="max-w-3xl">
          <h1
            id="jobs-title"
            className="text-4xl font-medium tracking-[-0.04em] text-balance sm:text-6xl"
          >
            {t("eyebrow")}
          </h1>
          <p className="mt-6 max-w-2xl text-xl leading-relaxed sm:text-2xl">
            {t("tagline")}
          </p>
          <p className="mt-6 max-w-2xl text-[15px] leading-7 text-muted">
            {t("intro")}
          </p>
        </header>

        <div className="mt-20 space-y-28 sm:mt-28 sm:space-y-36">
          <JobRoleSection namespace="jobs" roleId="founding-engineer" />
          <JobRoleSection
            namespace="jobs.foundingDesigner"
            roleId="founding-designer"
          />
        </div>
      </main>
    </div>
  );
}

function JobRoleSection({
  namespace,
  roleId,
}: {
  namespace: JobRoleNamespace;
  roleId: string;
}) {
  const t = useTranslations(namespace);
  const whatYoullDo = t.raw("whatYoullDoItems") as string[];
  const excitedItems = t.raw("excitedItems") as string[];
  const applyHref = `mailto:${applicationEmail}?subject=${encodeURIComponent(
    t("applyEmailSubject"),
  )}`;

  return (
    <section
      id={roleId}
      aria-labelledby={`${roleId}-title`}
      className="scroll-mt-24"
    >
      <header className="max-w-3xl">
        <h2
          id={`${roleId}-title`}
          className="text-3xl font-medium tracking-[-0.035em] text-balance sm:text-5xl"
        >
          {t("roleTitle")}
        </h2>
        <p className="mt-5 max-w-2xl text-lg leading-8 text-muted">
          {t("hiring")}
        </p>
      </header>

      <div className="mt-12 grid gap-10 lg:grid-cols-[minmax(0,1fr)_minmax(17rem,20rem)] lg:gap-16">
        <div className="min-w-0">
          <div className="grid gap-x-12 gap-y-14 md:grid-cols-2">
            <section aria-labelledby={`${roleId}-what-youll-do-title`}>
              <h3
                id={`${roleId}-what-youll-do-title`}
                className="text-xl font-medium tracking-tight"
              >
                {t("whatYoullDo")}
              </h3>
              <JobList items={whatYoullDo} />
            </section>

            <section aria-labelledby={`${roleId}-excited-title`}>
              <h3
                id={`${roleId}-excited-title`}
                className="text-xl font-medium tracking-tight"
              >
                {t("excitedLead")}
              </h3>
              <JobList items={excitedItems} />
            </section>
          </div>
        </div>

        <aside
          aria-label={t("details")}
          className="order-first self-start lg:order-last lg:sticky lg:top-20"
        >
          <div className="bg-code-bg/50 p-5 sm:p-6">
            <dl className="space-y-4 text-sm">
              <div>
                <dt className="text-muted">{t("compensationLabel")}</dt>
                <dd className="mt-1 font-medium tabular-nums">
                  {t("compensation")}
                </dd>
              </div>
              <div>
                <dt className="text-muted">{t("benefitsLabel")}</dt>
                <dd className="mt-1 font-medium">{t("benefits")}</dd>
              </div>
              <div>
                <dt className="text-muted">{t("locationLabel")}</dt>
                <dd className="mt-1 font-medium">{t("location")}</dd>
              </div>
            </dl>

            <a
              href={applyHref}
              aria-label={t("applyAriaLabel")}
              className={`mt-7 inline-flex min-h-11 w-full items-center justify-center gap-2 bg-foreground px-4 py-3 text-sm font-medium transition-colors hover:bg-foreground/85 ${focusRingClass}`}
              style={{ color: "var(--background)", textDecoration: "none" }}
            >
              {t("applyCta")}
              <ArrowIcon />
            </a>
          </div>
        </aside>
      </div>
    </section>
  );
}

function JobList({ items, compact = false }: { items: string[]; compact?: boolean }) {
  return (
    <ul
      className={`${compact ? "mt-4" : "mt-6"} space-y-4 text-[15px] leading-7 text-muted`}
    >
      {items.map((item) => (
        <li key={item} className="flex gap-3">
          <span
            aria-hidden="true"
            className="mt-[0.72rem] h-1.5 w-1.5 shrink-0 rounded-full bg-foreground/45"
          />
          <span>{item}</span>
        </li>
      ))}
    </ul>
  );
}

function ArrowIcon() {
  return (
    <svg
      aria-hidden="true"
      width="14"
      height="14"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M3 8h9" />
      <path d="m8.5 4.5 3.5 3.5-3.5 3.5" />
    </svg>
  );
}
