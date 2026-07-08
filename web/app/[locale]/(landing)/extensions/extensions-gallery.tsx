"use client";

import Image from "next/image";
import { useLocale, useTranslations } from "next-intl";
import { useEffect, useMemo, useRef, useState } from "react";
import { Link } from "../../../../i18n/navigation";

type ExtensionItem = {
  fullName: string;
  owner: string;
  ownerAvatarUrl: string;
  description: string | null;
  stars: number;
  language: string | null;
  pushedAt: string;
  createdAt: string;
  url: string;
  supported: boolean;
};

type IndexResponse = {
  extensions: ExtensionItem[];
  fetchedAt: string;
};

type SortMode = "popular" | "updated" | "newest" | "name";

const sortModes: SortMode[] = ["popular", "updated", "newest", "name"];

function repoName(fullName: string): string {
  return fullName.split("/").at(-1) ?? fullName;
}

function matchesQuery(extension: ExtensionItem, query: string): boolean {
  if (!query) return true;
  return [
    repoName(extension.fullName),
    extension.owner,
    extension.description,
    extension.language,
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase()
    .includes(query);
}

function compareDates(left: string, right: string): number {
  return new Date(right).getTime() - new Date(left).getTime();
}

function languageColor(language: string | null): string {
  if (!language) return "#8a8f98";
  let hash = 0;
  for (const char of language) {
    hash = (hash * 31 + char.charCodeAt(0)) % 360;
  }
  return `hsl(${hash} 55% 45%)`;
}

function installHref(fullName: string): string {
  return `cmux://extensions/install?repo=${encodeURIComponent(fullName)}`;
}

function installCommand(fullName: string): string {
  return `cmux extension install ${fullName}`;
}

const submitCommandExample = "cmux extension submit <owner>/<repo>";
const extensionSubmissionIssueUrl =
  "https://github.com/manaflow-ai/cmux/issues/new?template=extension-submission.yml";
const extensionTemplateUrl = "https://github.com/manaflow-ai/cmux-extension-template";

function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  return (
    target.isContentEditable ||
    target.tagName === "INPUT" ||
    target.tagName === "TEXTAREA" ||
    target.tagName === "SELECT"
  );
}

function relativeTime(value: string, formatter: Intl.RelativeTimeFormat): string {
  const timestamp = new Date(value).getTime();
  if (!Number.isFinite(timestamp)) return "";

  const diffSeconds = Math.round((timestamp - Date.now()) / 1000);
  const divisions: Array<[unit: Intl.RelativeTimeFormatUnit, seconds: number]> = [
    ["year", 60 * 60 * 24 * 365],
    ["month", 60 * 60 * 24 * 30],
    ["week", 60 * 60 * 24 * 7],
    ["day", 60 * 60 * 24],
    ["hour", 60 * 60],
    ["minute", 60],
  ];

  for (const [unit, seconds] of divisions) {
    const amount = Math.trunc(diffSeconds / seconds);
    if (Math.abs(amount) >= 1) {
      return formatter.format(amount, unit);
    }
  }
  return formatter.format(diffSeconds, "second");
}

export function ExtensionsGallery() {
  const t = useTranslations("extensions");
  const locale = useLocale();
  const searchRef = useRef<HTMLInputElement>(null);
  const copiedTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [query, setQuery] = useState("");
  const [sortMode, setSortMode] = useState<SortMode>("popular");
  const [extensions, setExtensions] = useState<ExtensionItem[]>([]);
  const [status, setStatus] = useState<"loading" | "ready" | "error">("loading");
  const [copiedFullName, setCopiedFullName] = useState<string | null>(null);
  const [copiedSubmitCommand, setCopiedSubmitCommand] = useState(false);

  const numberFormatter = useMemo(() => new Intl.NumberFormat(locale), [locale]);
  const collator = useMemo(
    () => new Intl.Collator(locale, { numeric: true, sensitivity: "base" }),
    [locale],
  );
  const relativeFormatter = useMemo(
    () => new Intl.RelativeTimeFormat(locale, { numeric: "auto" }),
    [locale],
  );

  useEffect(() => {
    const controller = new AbortController();

    fetch("/api/extensions/index", { signal: controller.signal })
      .then(async (response) => {
        if (!response.ok) {
          throw new Error(`extensions index ${response.status}`);
        }
        return response.json() as Promise<IndexResponse>;
      })
      .then((payload) => {
        setExtensions(payload.extensions);
        setStatus("ready");
      })
      .catch((error) => {
        if ((error as { name?: string }).name === "AbortError") return;
        setStatus("error");
      });

    return () => controller.abort();
  }, []);

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key !== "/" || event.metaKey || event.ctrlKey || event.altKey) {
        return;
      }
      if (isEditableTarget(event.target)) return;

      event.preventDefault();
      searchRef.current?.focus();
    }

    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  useEffect(() => {
    return () => {
      if (copiedTimeoutRef.current) {
        clearTimeout(copiedTimeoutRef.current);
      }
    };
  }, []);

  const normalizedQuery = query.trim().toLowerCase();
  const sortedExtensions = useMemo(() => {
    const filtered = extensions.filter((extension) =>
      matchesQuery(extension, normalizedQuery),
    );

    return filtered.sort((left, right) => {
      if (sortMode === "updated") {
        const delta = compareDates(left.pushedAt, right.pushedAt);
        return delta || collator.compare(left.fullName, right.fullName);
      }
      if (sortMode === "newest") {
        const delta = compareDates(left.createdAt, right.createdAt);
        return delta || collator.compare(left.fullName, right.fullName);
      }
      if (sortMode === "name") {
        return collator.compare(left.fullName, right.fullName);
      }

      return right.stars - left.stars || collator.compare(left.fullName, right.fullName);
    });
  }, [collator, extensions, normalizedQuery, sortMode]);

  async function copyCommand(fullName: string) {
    await navigator.clipboard.writeText(installCommand(fullName));
    setCopiedFullName(fullName);
    setCopiedSubmitCommand(false);
    if (copiedTimeoutRef.current) {
      clearTimeout(copiedTimeoutRef.current);
    }
    copiedTimeoutRef.current = setTimeout(() => setCopiedFullName(null), 1600);
  }

  async function copySubmitCommand() {
    await navigator.clipboard.writeText(submitCommandExample);
    setCopiedFullName(null);
    setCopiedSubmitCommand(true);
    if (copiedTimeoutRef.current) {
      clearTimeout(copiedTimeoutRef.current);
    }
    copiedTimeoutRef.current = setTimeout(() => setCopiedSubmitCommand(false), 1600);
  }

  return (
    <div className="not-prose">
      <div className="mb-6 rounded-lg border border-border p-4">
        <p className="mb-4 text-sm leading-6 text-muted">
          {t.rich("trustNote", {
            link: (chunks) => (
              <Link
                href="/docs/extensions#trust-and-security"
                className="font-medium underline underline-offset-2"
              >
                {chunks}
              </Link>
            ),
          })}
        </p>
        <div className="grid gap-3 md:grid-cols-[1fr_220px]">
          <label className="grid min-w-0 gap-1.5">
            <span className="text-xs text-muted">{t("searchLabel")}</span>
            <input
              ref={searchRef}
              type="search"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder={t("searchPlaceholder")}
              aria-label={t("searchLabel")}
              className="h-10 w-full min-w-0 rounded-md border border-border bg-background px-3 text-sm outline-none transition-colors placeholder:text-muted focus:border-foreground"
            />
          </label>
          <label className="grid min-w-0 gap-1.5">
            <span className="text-xs text-muted">{t("sortLabel")}</span>
            <select
              value={sortMode}
              onChange={(event) => setSortMode(event.target.value as SortMode)}
              className="h-10 w-full min-w-0 rounded-md border border-border bg-background px-3 text-sm outline-none transition-colors focus:border-foreground"
            >
              {sortModes.map((mode) => (
                <option key={mode} value={mode}>
                  {t(`sort.${mode}`)}
                </option>
              ))}
            </select>
          </label>
        </div>
      </div>

      <div className="mb-4 flex flex-wrap items-center justify-between gap-3 text-xs text-muted">
        <span>
          {status === "ready"
            ? t("showingCount", {
                count: numberFormatter.format(sortedExtensions.length),
                total: numberFormatter.format(extensions.length),
              })
            : t(`state.${status}`)}
        </span>
        <span>{t("shortcutHint")}</span>
      </div>

      {status === "error" ? (
        <div className="rounded-lg border border-border px-4 py-10 text-center text-sm">
          {t("state.error")}
        </div>
      ) : null}

      {status === "loading" ? (
        <div className="rounded-lg border border-border px-4 py-10 text-center text-sm">
          {t("state.loading")}
        </div>
      ) : null}

      {status === "ready" && sortedExtensions.length === 0 ? (
        <div className="rounded-lg border border-border px-4 py-10 text-center">
          <div className="text-sm font-medium">{t("emptyTitle")}</div>
          <p className="mt-2 text-sm text-muted">{t("emptyDescription")}</p>
        </div>
      ) : null}

      {status === "ready" && sortedExtensions.length > 0 ? (
        <div className="grid gap-4 md:grid-cols-2">
          {sortedExtensions.map((extension) => (
            <article
              key={extension.fullName}
              className="flex h-full flex-col rounded-lg border border-border p-4"
            >
              <div className="flex min-w-0 items-start gap-3">
                <Image
                  src={extension.ownerAvatarUrl}
                  alt=""
                  width={32}
                  height={32}
                  className="mt-0.5 rounded-md"
                />
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <h2 className="break-words text-[15px] font-semibold leading-6">
                      {repoName(extension.fullName)}
                    </h2>
                    {extension.supported ? (
                      <span className="inline-flex items-center gap-1 rounded-full border border-emerald-500/30 bg-emerald-500/10 px-2 py-0.5 text-[11px] font-medium text-emerald-700 dark:text-emerald-300">
                        <span aria-hidden="true">✓</span>
                        {t("supportedLabel")}
                      </span>
                    ) : null}
                  </div>
                  <div className="break-words text-xs text-muted">
                    {extension.owner}
                  </div>
                </div>
              </div>

              <p className="mt-3 flex-1 text-sm leading-6 text-muted">
                {extension.description ?? t("noDescription")}
              </p>

              <div className="mt-4 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted">
                <span>
                  {"★ "}
                  {numberFormatter.format(extension.stars)}
                </span>
                <span className="inline-flex items-center gap-1.5">
                  <span
                    className="h-2 w-2 rounded-full"
                    style={{ backgroundColor: languageColor(extension.language) }}
                  />
                  {extension.language ?? t("unknownLanguage")}
                </span>
                <span>
                  {t("updatedLabel", {
                    time: relativeTime(extension.pushedAt, relativeFormatter),
                  })}
                </span>
              </div>

              <div className="mt-5 rounded-md bg-code-bg px-3 py-2 text-[12px] leading-5">
                <code className="break-all">{installCommand(extension.fullName)}</code>
              </div>

              <div className="mt-3 flex flex-wrap items-center gap-2">
                <a
                  href={installHref(extension.fullName)}
                  className="rounded-md bg-foreground px-3 py-2 text-sm font-medium text-background transition-opacity hover:opacity-85"
                >
                  {t("installAction")}
                </a>
                <button
                  type="button"
                  onClick={() => void copyCommand(extension.fullName)}
                  className="rounded-md border border-border px-3 py-2 text-sm font-medium transition-colors hover:bg-code-bg"
                >
                  {copiedFullName === extension.fullName
                    ? t("copiedAction")
                    : t("copyAction")}
                </button>
                <a
                  href={extension.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-sm font-medium underline underline-offset-2"
                >
                  {t("githubAction")}
                </a>
              </div>
            </article>
          ))}
        </div>
      ) : null}

      <section className="mt-10 border-t border-border pt-8">
        <h2 className="text-lg font-semibold tracking-tight">{t("submitTitle")}</h2>
        <p className="mt-2 max-w-3xl text-sm leading-6 text-muted">{t("submitBody")}</p>
        <div className="mt-4 grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
          <div className="rounded-md bg-code-bg px-3 py-2 text-[12px] leading-5">
            <code className="break-all">{submitCommandExample}</code>
          </div>
          <button
            type="button"
            onClick={() => void copySubmitCommand()}
            className="rounded-md border border-border px-3 py-2 text-sm font-medium transition-colors hover:bg-code-bg"
          >
            {copiedSubmitCommand ? t("copiedAction") : t("copyAction")}
          </button>
        </div>
        <div className="mt-4 flex flex-wrap gap-3">
          <a
            href={extensionSubmissionIssueUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="rounded-md border border-border px-3 py-2 text-sm font-medium transition-colors hover:bg-code-bg"
          >
            {t("submitIssueAction")}
          </a>
          <a
            href={extensionTemplateUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="rounded-md border border-border px-3 py-2 text-sm font-medium transition-colors hover:bg-code-bg"
          >
            {t("templateAction")}
          </a>
          <Link
            href="/docs/extensions-marketplace"
            className="rounded-md border border-border px-3 py-2 text-sm font-medium transition-colors hover:bg-code-bg"
          >
            {t("marketplaceDocsAction")}
          </Link>
        </div>
      </section>
    </div>
  );
}
