import { getTranslations } from "next-intl/server";
import { Link } from "@/i18n/navigation";
import { CopySnippet } from "./copy-snippet";
import { JsonLd } from "@/app/[locale]/components/json-ld";
import { Readme } from "@/app/lib/extensions/readme";
import type { Listing } from "@/app/lib/extensions/registry";
import {
  GITHUB_HOST,
  authorPath,
  badgeSnippet,
  installPath,
  installReference,
  listingPath,
  releaseUrl,
  remixPath,
  repositoryTreeUrl,
} from "@/app/lib/extensions/refs";
import { listingJsonLd, listingSummary } from "@/app/lib/extensions/seo";

const BUTTON_PRIMARY =
  "inline-flex items-center justify-center rounded-full bg-foreground px-5 py-2 text-[14px] font-medium transition-opacity hover:opacity-85";
const BUTTON_SECONDARY =
  "inline-flex items-center justify-center rounded-full border border-border px-4 py-2 text-[14px] font-medium transition-colors hover:bg-code-bg";

function compactNumber(value: number): string {
  return new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 }).format(value);
}

export function ListingIcon({ listing, size }: { listing: Listing; size: number }) {
  const radius = Math.round(size * 0.22);
  if (listing.iconUrl) {
    return (
      // eslint-disable-next-line @next/next/no-img-element -- remote icon at the reviewed commit; the optimizer gains nothing at this size
      <img
        src={listing.iconUrl}
        alt=""
        width={size}
        height={size}
        loading="lazy"
        decoding="async"
        referrerPolicy="no-referrer"
        className="shrink-0 border border-border bg-code-bg object-cover"
        style={{ borderRadius: radius, width: size, height: size }}
      />
    );
  }
  return (
    <div
      aria-hidden
      className="flex shrink-0 items-center justify-center border border-border bg-code-bg font-semibold text-muted"
      style={{ borderRadius: radius, width: size, height: size, fontSize: Math.round(size * 0.42) }}
    >
      {listing.name.slice(0, 1).toUpperCase()}
    </div>
  );
}

/** Downloads and stars, as one muted line. */
export async function ListingStats({ listing, prefix = "" }: { listing: Listing; prefix?: string }) {
  const t = await getTranslations("extensions");
  const parts: string[] = [];
  if (listing.downloads !== undefined) parts.push(t("downloads", { count: listing.downloads, display: compactNumber(listing.downloads) }));
  if (listing.stars !== undefined) parts.push(t("stars", { count: listing.stars, display: compactNumber(listing.stars) }));
  if (parts.length === 0) return null;
  return <span>{prefix}{parts.join(" · ")}</span>;
}

export function categoryLabel(category: string): string {
  return category.replace(/[-_]+/g, " ").replace(/^\p{Ll}/u, (c) => c.toUpperCase());
}

const TIER_LABEL = { plugin: "tierPluginOne", theme: "tierThemeOne", snippet: "tierSnippetOne", setup: "tierSetupOne" } as const;

function hostLabel(host: string): string {
  if (host === GITHUB_HOST) return "GitHub";
  if (host === "gitlab.com") return "GitLab";
  if (host === "codeberg.org") return "Codeberg";
  return host;
}

/** Install, View source and Fork and customize. */
export async function ListingActions({ listing }: { listing: Listing }) {
  const t = await getTranslations("extensions");
  return (
    <div className="flex flex-wrap items-center gap-2">
      <Link
        href={installPath(listing, listing.kind)}
        className={BUTTON_PRIMARY}
        style={{ color: "var(--background)", textDecoration: "none" }}
        rel="nofollow"
      >
        {t("install")}
      </Link>
      <a href={repositoryTreeUrl(listing, listing.commit)} className={BUTTON_SECONDARY} rel="noopener">
        {t("viewSourceOn", { host: hostLabel(listing.host) })}
      </a>
      {/* The remix link (remix.md) forks an extension; a setup is customized by installing it. */}
      {listing.kind === "extension" ? (
        <Link href={remixPath(listing, listing.kind)} className={BUTTON_SECONDARY} rel="nofollow">
          {t("forkAndCustomize")}
        </Link>
      ) : null}
    </div>
  );
}

function DetailRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex justify-between gap-4 border-b border-border py-2 text-[13px] last:border-b-0">
      <dt className="text-muted">{label}</dt>
      <dd className="min-w-0 truncate text-right">{children}</dd>
    </div>
  );
}

export async function ListingDetails({ listing }: { listing: Listing }) {
  const t = await getTranslations("extensions");
  const updated = listing.latest?.date ?? listing.updatedAt;
  return (
    <dl>
      <DetailRow label={t("type")}>{t(TIER_LABEL[listing.tier])}</DetailRow>
      {listing.latest ? (
        <DetailRow label={t("latestRelease")}>
          {listing.latest.tag ? (
            <a href={releaseUrl(listing, listing.latest.tag)} className="underline decoration-link-underline underline-offset-2">
              v{listing.latest.version}
            </a>
          ) : (
            `v${listing.latest.version}`
          )}
        </DetailRow>
      ) : null}
      {listing.downloads !== undefined ? <DetailRow label={t("downloadsLabel")}>{listing.downloads.toLocaleString("en")}</DetailRow> : null}
      {updated ? (
        <DetailRow label={t("updated")}>
          <time dateTime={updated}>{updated.slice(0, 10)}</time>
        </DetailRow>
      ) : null}
      <DetailRow label={t("publisher")}>
        <Link href={authorPath(listing.owner)} className="underline decoration-link-underline underline-offset-2">
          {listing.publisher ?? listing.owner}
        </Link>
      </DetailRow>
      {listing.categories.length > 0 ? (
        <DetailRow label={t("categories")}>
          {listing.categories.map(categoryLabel).join(", ")}
        </DetailRow>
      ) : null}
      {listing.license ? <DetailRow label={t("license")}>{listing.license}</DetailRow> : null}
      {listing.requiresCmux ? <DetailRow label="cmux">{`${listing.requiresCmux}+`}</DetailRow> : null}
      <DetailRow label={t("version")}>
        <a href={repositoryTreeUrl(listing, listing.commit)} className="font-mono underline decoration-link-underline underline-offset-2">
          {listing.commit.slice(0, 7)}
        </a>
      </DetailRow>
    </dl>
  );
}

export async function BadgeSnippet({ listing }: { listing: Listing }) {
  const t = await getTranslations("extensions");
  return (
    <section aria-labelledby="badge-title">
      <h2 id="badge-title" className="text-[15px] font-semibold">{t("badgeTitle")}</h2>
      <p className="mb-3 mt-1 text-[13px] text-muted">{t("badgeBody")}</p>
      {/* eslint-disable-next-line @next/next/no-img-element -- the badge itself, served as SVG */}
      <img src="/extensions/badge.svg" alt="Get it on cmux" height={44} className="mb-3 h-11 w-auto" />
      <CopySnippet text={badgeSnippet(listing, listing.kind)} copyLabel={t("copy")} copiedLabel={t("copied")} />
    </section>
  );
}

export async function SetupContents({ listing }: { listing: Listing }) {
  const t = await getTranslations("extensions");
  if (listing.contents.length === 0) return null;
  return (
    <section aria-labelledby="setup-contents" className="mb-8">
      <h2 id="setup-contents" className="mb-3 text-lg font-semibold tracking-tight">{t("setupContents")}</h2>
      <ul className="divide-y divide-border rounded-xl border border-border">
        {listing.contents.map((item, index) => (
          <li key={`${item.kind}-${index}`} className="flex items-center justify-between gap-4 px-4 py-2.5 text-[14px]">
            <span className="min-w-0 truncate">{item.name}</span>
            <span className="shrink-0 rounded-full border border-border px-2 py-0.5 text-[12px] text-muted">{categoryLabel(item.kind)}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}

export function Screenshots({ listing }: { listing: Listing }) {
  if (listing.screenshots.length === 0) return null;
  return (
    <div className="-mx-1 mb-8 flex snap-x gap-3 overflow-x-auto px-1 pb-2">
      {listing.screenshots.map((src, index) => (
        <a key={src} href={src} className="block shrink-0 snap-start overflow-hidden rounded-xl border border-border bg-code-bg">
          {/* eslint-disable-next-line @next/next/no-img-element -- screenshots at the reviewed commit, any size */}
          <img
            src={src}
            alt={`${listing.name} screenshot ${index + 1}`}
            loading={index === 0 ? "eager" : "lazy"}
            decoding="async"
            referrerPolicy="no-referrer"
            className="block h-64 w-auto max-w-none sm:h-80"
          />
        </a>
      ))}
    </div>
  );
}

export function CliInstall({ listing, label, copy, copied }: { listing: Listing; label: string; copy: string; copied: string }) {
  const command = listing.kind === "setup"
    ? `cmux setup install ${installReference(listing)}@${listing.commit}`
    : `cmux apps install ${installReference(listing)}@${listing.commit}`;
  return (
    <div>
      <p className="mb-2 text-[13px] text-muted">{label}</p>
      <CopySnippet text={command} copyLabel={copy} copiedLabel={copied} />
    </div>
  );
}

/**
 * A listing's page body: header with the actions, then the README beside a details sidebar
 * (install command, badge, more by the author). Of the three layouts tried (sidebar, stacked,
 * centered hero; screenshots on the PR), the sidebar keeps install and the badge above the fold.
 */
export async function ListingDetail({ listing, more }: { listing: Listing; more: readonly Listing[] }) {
  const t = await getTranslations("extensions");
  const header = (
    <header className="mb-8 flex items-start gap-5">
      <ListingIcon listing={listing} size={72} />
      <div className="min-w-0">
        <h1 className="text-3xl font-semibold tracking-tight">{listing.name}</h1>
        <p className="mt-1 text-[16px] text-muted">{listingSummary(listing)}</p>
        <p className="mt-2 flex flex-wrap items-center gap-x-2 text-[13px] text-muted">
          <Link href={authorPath(listing.owner)} className="text-foreground underline decoration-link-underline underline-offset-2">
            {listing.publisher ?? listing.owner}
          </Link>
          <ListingStats listing={listing} prefix="· " />
          {listing.latest ? <span>· v{listing.latest.version}</span> : null}
          {listing.requiresCmux ? <span>· {t("requires", { version: listing.requiresCmux })}</span> : null}
        </p>
        <div className="mt-4">
          <ListingActions listing={listing} />
        </div>
      </div>
    </header>
  );
  const body = (
    <>
      <Screenshots listing={listing} />
      {listing.description && listing.description !== listingSummary(listing) ? (
        <p className="mb-8 max-w-3xl text-[15px] leading-7">{listing.description}</p>
      ) : null}
      <SetupContents listing={listing} />
      {listing.readme ? (
        <section aria-label={t("readme")} className="docs-content min-w-0 rounded-xl border border-border px-6 py-5">
          <Readme source={listing} markdown={listing.readme} />
        </section>
      ) : null}
    </>
  );
  const aside = (
    <>
      <section aria-label={t("details")}>
        <ListingDetails listing={listing} />
      </section>
      <CliInstall listing={listing} label={t("installCommand")} copy={t("copy")} copied={t("copied")} />
      <BadgeSnippet listing={listing} />
      {more.length > 0 ? (
        <section>
          <h2 className="mb-2 text-[15px] font-semibold">{t("moreBy", { owner: listing.publisher ?? listing.owner })}</h2>
          <ul className="space-y-2">
            {more.slice(0, 5).map((other) => (
              <li key={listingPath(other, other.kind)}>
                <Link href={listingPath(other, other.kind)} className="flex items-center gap-2 text-[14px] hover:underline">
                  <ListingIcon listing={other} size={24} />
                  <span className="truncate">{other.name}</span>
                </Link>
              </li>
            ))}
          </ul>
        </section>
      ) : null}
    </>
  );
  return (
    <article>
      <JsonLd data={listingJsonLd(listing)} />
      {header}
      <div className="grid gap-10 lg:grid-cols-[minmax(0,1fr)_300px]">
        <div className="min-w-0">{body}</div>
        <aside className="space-y-8">{aside}</aside>
      </div>
    </article>
  );
}
