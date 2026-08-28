import type { Metadata } from "next";
import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { Link } from "@/i18n/navigation";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import {
  fallbackContentLocales,
  hasFallbackContent,
} from "@/i18n/locale-availability";
import {
  buildAlternates,
  openGraphDefaults,
  seoDescription,
  twitterSummary,
} from "@/i18n/seo";

export type JobRoleNamespace = "jobs" | "jobs.foundingDesigner";

type JobRolePageProps = {
  namespace: JobRoleNamespace;
  backHref?: string;
  roleLinkHref: string;
  showRoleDirectory?: boolean;
};

const focusRingClass =
  "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-foreground";
const applicationEmail = "founders@cmux.com";

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
  const contentLocale = hasFallbackContent(locale) ? locale : "en";
  const t = await getTranslations({ locale: contentLocale, namespace });
  const title = t("metaTitle");
  const description = seoDescription(contentLocale, t("metaDescription"), {
    minLength: 110,
    appendLocalizedContext: false,
  });
  const alternates = buildAlternates(
    contentLocale,
    path,
    fallbackContentLocales,
  );

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

export function JobRolePage({
  namespace,
  backHref,
  roleLinkHref,
  showRoleDirectory = false,
}: JobRolePageProps) {
  const t = useTranslations(namespace);
  const whatYoullDo = t.raw("whatYoullDoItems") as string[];
  const whoWereLookingFor = t.raw("whoWereLookingForItems") as string[];
  const applyHref = `mailto:${applicationEmail}?subject=${encodeURIComponent(
    t("applyEmailSubject"),
  )}`;

  return (
    <div className="min-h-screen">
      <SiteHeader section={t("section")} />

      <main
        aria-labelledby="jobs-title"
        className="mx-auto w-full max-w-6xl px-6 py-14 sm:py-20"
      >
        {backHref ? (
          <Link
            href={backHref}
            className={`mb-8 inline-flex items-center gap-2 text-sm text-muted transition-colors hover:text-foreground ${focusRingClass}`}
          >
            <span aria-hidden="true">←</span>
            {t("backToAllRoles")}
          </Link>
        ) : null}

        <div className="grid gap-12 lg:grid-cols-[minmax(0,1fr)_minmax(18rem,22rem)] lg:gap-20">
          <header className="max-w-3xl">
            <p className="mb-4 text-sm font-medium tracking-tight text-muted">
              {t("eyebrow")}
            </p>
            <h1
              id="jobs-title"
              className="max-w-3xl text-4xl font-medium tracking-[-0.04em] text-balance sm:text-6xl"
            >
              {t("title")}
            </h1>
            <p className="mt-6 max-w-2xl text-xl leading-relaxed sm:text-2xl">
              {t("tagline")}
            </p>
            <div className="mt-8 max-w-2xl space-y-4 text-[15px] leading-7 text-muted">
              <p>{t("intro")}</p>
              <p>{t("hiring")}</p>
            </div>
          </header>

          <aside
            aria-labelledby="role-details-title"
            className="self-start lg:sticky lg:top-20"
          >
            <div className="border border-border bg-code-bg/40 p-5 sm:p-6">
              <p className="text-xs font-medium uppercase tracking-[0.14em] text-muted">
                {t("details")}
              </p>
              <h2
                id="role-details-title"
                className="mt-3 text-xl font-medium tracking-tight"
              >
                {t("roleTitle")}
              </h2>

              <dl className="mt-6 space-y-4 text-sm">
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

              <div className="mt-6 border-t border-border pt-5">
                <p className="text-xs font-medium uppercase tracking-[0.14em] text-muted">
                  {t("otherRoleEyebrow")}
                </p>
                <Link
                  href={roleLinkHref}
                  className={`mt-3 inline-flex items-center gap-2 text-sm font-medium underline decoration-link-underline underline-offset-4 transition-colors hover:decoration-foreground ${focusRingClass}`}
                >
                  {t("otherRoleTitle")}
                  <ArrowIcon />
                </Link>
              </div>
            </div>
          </aside>
        </div>

        {showRoleDirectory ? (
          <section
            aria-labelledby="open-roles-title"
            className="mt-14 border-y border-border py-8 sm:mt-16 sm:py-10"
          >
            <div className="flex flex-col gap-5 sm:flex-row sm:items-end sm:justify-between sm:gap-10">
              <div>
                <p className="text-xs font-medium uppercase tracking-[0.14em] text-muted">
                  {t("openRolesEyebrow")}
                </p>
                <h2
                  id="open-roles-title"
                  className="mt-3 text-2xl font-medium tracking-tight"
                >
                  {t("openRolesTitle")}
                </h2>
                <p className="mt-2 max-w-md text-[15px] leading-7 text-muted">
                  {t("openRolesBody")}
                </p>
              </div>

              <div className="grid w-full gap-3 sm:max-w-xl sm:grid-cols-2">
                <Link
                  href="/jobs"
                  aria-current="page"
                  className={`group flex min-h-14 items-center justify-between gap-4 border border-foreground bg-code-bg/40 px-4 py-3 text-sm font-medium transition-colors hover:bg-code-bg ${focusRingClass}`}
                >
                  <span>{t("roleTitle")}</span>
                  <ArrowIcon />
                </Link>
                <Link
                  href="/jobs/founding-designer"
                  className={`group flex min-h-14 items-center justify-between gap-4 border border-border px-4 py-3 text-sm font-medium transition-colors hover:border-foreground ${focusRingClass}`}
                >
                  <span>{t("otherRoleTitle")}</span>
                  <ArrowIcon />
                </Link>
              </div>
            </div>
          </section>
        ) : null}

        <div className="mt-16 grid gap-14 border-t border-border pt-12 lg:mt-20">
          <div className="max-w-3xl">
            <section aria-labelledby="what-youll-do-title">
              <h2
                id="what-youll-do-title"
                className="text-2xl font-medium tracking-tight"
              >
                {t("whatYoullDo")}
              </h2>
              <ul className="mt-6 space-y-4 text-[15px] leading-7 text-muted">
                {whatYoullDo.map((item) => (
                  <li key={item} className="flex gap-3">
                    <span
                      aria-hidden="true"
                      className="mt-[0.72rem] h-1.5 w-1.5 shrink-0 rounded-full bg-foreground/45"
                    />
                    <span>{item}</span>
                  </li>
                ))}
              </ul>
            </section>

            <section
              aria-labelledby="who-were-looking-for-title"
              className="mt-14 border-t border-border pt-10"
            >
              <h2
                id="who-were-looking-for-title"
                className="text-2xl font-medium tracking-tight"
              >
                {t("whoWereLookingFor")}
              </h2>
              <p className="mt-5 text-[15px] leading-7 text-muted">
                {t("whoIntro")}
              </p>
              <p className="mt-6 text-[15px] font-medium leading-7">
                {t("excitedLead")}
              </p>
              <ul className="mt-4 space-y-4 text-[15px] leading-7 text-muted">
                {whoWereLookingFor.map((item) => (
                  <li key={item} className="flex gap-3">
                    <span
                      aria-hidden="true"
                      className="mt-[0.72rem] h-1.5 w-1.5 shrink-0 rounded-full bg-foreground/45"
                    />
                    <span>{item}</span>
                  </li>
                ))}
              </ul>
            </section>

            <section
              aria-labelledby="about-cmux-title"
              className="mt-14 border-t border-border pt-10"
            >
              <h2
                id="about-cmux-title"
                className="text-2xl font-medium tracking-tight"
              >
                {t("aboutTitle")}
              </h2>
              <p className="mt-5 text-[15px] leading-7 text-muted">
                {t("aboutBody")}
              </p>
            </section>
          </div>
        </div>

        <section
          aria-labelledby="apply-title"
          className="mt-16 border-t border-border pt-10 sm:mt-20"
        >
          <div className="flex flex-col gap-6 border border-border p-5 sm:flex-row sm:items-center sm:justify-between sm:p-8">
            <div>
              <p className="text-xs font-medium uppercase tracking-[0.14em] text-muted">
                {t("applyEyebrow")}
              </p>
              <h2
                id="apply-title"
                className="mt-3 text-2xl font-medium tracking-tight"
              >
                {t("applyTitle")}
              </h2>
              <p className="mt-3 max-w-xl text-[15px] leading-7 text-muted">
                {t("applyBody")}
              </p>
            </div>
            <a
              href={applyHref}
              className={`inline-flex min-h-11 shrink-0 items-center justify-center gap-2 border border-foreground px-4 py-3 text-sm font-medium transition-colors hover:bg-foreground hover:text-background ${focusRingClass}`}
            >
              {t("applyCta")}
              <ArrowIcon />
            </a>
          </div>
        </section>
      </main>
    </div>
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
