import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import { buildAlternates } from "../../../../i18n/seo";
import { Link } from "../../../../i18n/navigation";
import { SiteHeader } from "../../components/site-header";
import { DOWNLOAD_CONFIRMATION_HREF } from "../../../lib/download";

type SearchValue = string | string[] | undefined;
type SearchParams = Record<string, SearchValue>;

type LinkKind = "ssh" | "prompt" | "rules";

const definitions: Record<
  LinkKind,
  {
    allowedParams: readonly string[];
    requiredParams: readonly string[];
    exampleHref: string;
  }
> = {
  ssh: {
    allowedParams: [
      "host",
      "user",
      "port",
      "title",
      "name",
      "connect-timeout",
      "server-alive-interval",
      "server-alive-count-max",
      "host-key-policy",
      "no-focus",
    ],
    requiredParams: ["host"],
    exampleHref:
      "/deeplink/ssh?host=dev.example.com&user=alice&port=2222&title=GPU%20box",
  },
  prompt: {
    allowedParams: ["text", "title", "name", "no-focus"],
    requiredParams: ["text"],
    exampleHref: "/deeplink/prompt?text=Review%20this%20branch",
  },
  rules: {
    allowedParams: ["text", "name", "title", "no-focus"],
    requiredParams: ["text"],
    exampleHref:
      "/deeplink/rules?name=freestyle&text=Prefer%20small%20PRs",
  },
};

function canonicalKind(rawKind: string): LinkKind | null {
  if (rawKind === "rule") return "rules";
  if (rawKind === "ssh" || rawKind === "prompt" || rawKind === "rules") {
    return rawKind;
  }
  return null;
}

function firstString(value: SearchValue): string | null {
  if (typeof value === "string") return value;
  return null;
}

function duplicatedParams(params: SearchParams, allowedParams: readonly string[]) {
  return allowedParams.filter((name) => Array.isArray(params[name]));
}

function unsupportedParams(params: SearchParams, allowedParams: readonly string[]) {
  const allowed = new Set(allowedParams);
  return Object.keys(params).filter((name) => !allowed.has(name));
}

function missingParams(params: SearchParams, requiredParams: readonly string[]) {
  return requiredParams.filter((name) => {
    const value = firstString(params[name]);
    return value == null || value.trim() === "";
  });
}

function normalizedParam(params: SearchParams, name: string) {
  const value = firstString(params[name])?.trim();
  return value ? value : null;
}

function conflictingParams(kind: LinkKind, params: SearchParams) {
  if (
    kind === "ssh" &&
    normalizedParam(params, "title") &&
    normalizedParam(params, "name")
  ) {
    return ["title, name"];
  }
  return [];
}

function uniqueParamNames(params: string[]) {
  return Array.from(new Set(params));
}

function isBoundedInteger(value: string, min: number, max: number) {
  if (!/^[0-9]+$/.test(value)) return false;
  const integer = Number(value);
  return Number.isSafeInteger(integer) && integer >= min && integer <= max;
}

function containsUnsafeHiddenCharacter(value: string) {
  return /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(value);
}

function invalidTextParams(params: SearchParams) {
  const invalid: string[] = [];
  const text = firstString(params.text);
  if (
    text != null &&
    (text.length > 8000 || containsUnsafeHiddenCharacter(text))
  ) {
    invalid.push("text");
  }

  const name = normalizedParam(params, "name");
  if (
    name != null &&
    (name.length > 120 || containsUnsafeHiddenCharacter(name))
  ) {
    invalid.push("name");
  }

  const title = normalizedParam(params, "title");
  if (
    title != null &&
    (title.length > 160 || containsUnsafeHiddenCharacter(title))
  ) {
    invalid.push("title");
  }
  return invalid;
}

function isAllowedSSHHost(value: string) {
  if (containsUnsafeHiddenCharacter(value)) return false;
  if (value.startsWith("[") || value.endsWith("]")) {
    if (!value.startsWith("[") || !value.endsWith("]")) return false;
    const inner = value.slice(1, -1);
    return inner !== "" && /^[0-9A-Za-z:.%]+$/.test(inner);
  }
  return /^[A-Za-z0-9._%-]+$/.test(value);
}

function isAllowedSSHUser(value: string) {
  return (
    !containsUnsafeHiddenCharacter(value) &&
    /^[A-Za-z0-9._%+=,:-]+$/.test(value)
  );
}

function invalidParams(kind: LinkKind, params: SearchParams) {
  const invalid: string[] = [];
  const noFocus = normalizedParam(params, "no-focus");
  if (
    noFocus != null &&
    noFocus !== "" &&
    !["1", "true", "yes", "on", "0", "false", "no", "off"].includes(
      noFocus.toLowerCase(),
    )
  ) {
    invalid.push("no-focus");
  }

  if (kind !== "ssh") {
    invalid.push(...invalidTextParams(params));
    return invalid;
  }

  const host = normalizedParam(params, "host");
  const user = normalizedParam(params, "user");
  if (host != null && (host.startsWith("-") || !isAllowedSSHHost(host))) {
    invalid.push("host");
  }
  if (user != null && (user.startsWith("-") || !isAllowedSSHUser(user))) {
    invalid.push("user");
  }
  const destination = user && host ? `${user}@${host}` : host;
  if (destination != null && destination.length > 256) {
    invalid.push(user ? "user, host" : "host");
  }
  const title = normalizedParam(params, "title");
  if (
    title != null &&
    (title.length > 160 || containsUnsafeHiddenCharacter(title))
  ) {
    invalid.push("title");
  }
  const name = normalizedParam(params, "name");
  if (
    name != null &&
    (name.length > 160 || containsUnsafeHiddenCharacter(name))
  ) {
    invalid.push("name");
  }

  const port = normalizedParam(params, "port");
  if (port != null && !isBoundedInteger(port, 1, 65535)) {
    invalid.push("port");
  }
  const connectTimeout = normalizedParam(params, "connect-timeout");
  if (connectTimeout != null && !isBoundedInteger(connectTimeout, 1, 600)) {
    invalid.push("connect-timeout");
  }
  const serverAliveInterval = normalizedParam(params, "server-alive-interval");
  if (
    serverAliveInterval != null &&
    !isBoundedInteger(serverAliveInterval, 1, 3600)
  ) {
    invalid.push("server-alive-interval");
  }
  const serverAliveCountMax = normalizedParam(params, "server-alive-count-max");
  if (
    serverAliveCountMax != null &&
    !isBoundedInteger(serverAliveCountMax, 1, 100)
  ) {
    invalid.push("server-alive-count-max");
  }
  const hostKeyPolicy = normalizedParam(params, "host-key-policy");
  if (
    hostKeyPolicy != null &&
    !["accept-new", "ask", "strict", "yes"].includes(
      hostKeyPolicy.toLowerCase(),
    )
  ) {
    invalid.push("host-key-policy");
  }
  return invalid;
}

function nativeQueryValue(name: string, value: string) {
  if (name === "text") return value;
  const normalized = value.trim();
  if (normalized !== "") return normalized;
  return name === "no-focus" ? "" : null;
}

function nativeHref(kind: LinkKind, params: SearchParams) {
  const definition = definitions[kind];
  const query = new URLSearchParams();
  for (const name of definition.allowedParams) {
    const value = firstString(params[name]);
    if (value != null) {
      const queryValue = nativeQueryValue(name, value);
      if (queryValue != null) {
        query.set(name, queryValue);
      }
    }
  }
  const queryString = query.toString().replace(/\+/g, "%20");
  return `cmux://${kind}${queryString ? `?${queryString}` : ""}`;
}

export function generateStaticParams() {
  return [
    { kind: "ssh" },
    { kind: "prompt" },
    { kind: "rules" },
    { kind: "rule" },
  ];
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string; kind: string }>;
}) {
  const { locale, kind: rawKind } = await params;
  const kind = canonicalKind(rawKind);
  if (!kind) notFound();

  const t = await getTranslations({ locale, namespace: "deeplink" });
  return {
    title: t(`${kind}.metaTitle`),
    description: t(`${kind}.metaDescription`),
    alternates: buildAlternates(locale, `/deeplink/${kind}`),
  };
}

export default async function DeeplinkPage({
  params,
  searchParams,
}: {
  params: Promise<{ kind: string }>;
  searchParams?: Promise<SearchParams>;
}) {
  const { kind: rawKind } = await params;
  const kind = canonicalKind(rawKind);
  if (!kind) notFound();

  const t = await getTranslations("deeplink");
  const resolvedSearchParams = (await searchParams) ?? {};
  const definition = definitions[kind];
  const unsupported = unsupportedParams(
    resolvedSearchParams,
    definition.allowedParams,
  );
  const duplicates = duplicatedParams(resolvedSearchParams, definition.allowedParams);
  const conflicts = conflictingParams(kind, resolvedSearchParams);
  const invalid = uniqueParamNames(invalidParams(kind, resolvedSearchParams));
  const missing = missingParams(resolvedSearchParams, definition.requiredParams);
  const href = nativeHref(kind, resolvedSearchParams);
  const canOpen =
    unsupported.length === 0 &&
    duplicates.length === 0 &&
    conflicts.length === 0 &&
    invalid.length === 0 &&
    missing.length === 0;
  const errorMessage =
    unsupported.length > 0
      ? t("unsupportedParams", { params: unsupported.join(", ") })
      : duplicates.length > 0
        ? t("duplicateParams", { params: duplicates.join(", ") })
        : conflicts.length > 0
          ? t("conflictingParams", { params: conflicts.join(", ") })
          : invalid.length > 0
            ? t("invalidParams", { params: invalid.join(", ") })
            : t("missingParams", { params: missing.join(", ") });

  return (
    <div className="min-h-screen">
      <SiteHeader section={t("section")} />
      <main className="mx-auto w-full max-w-2xl px-6 py-12">
        <div className="mb-8 flex items-center gap-4">
          {/* Plain <img> (raw PNG), not next/image, on purpose — same
              optimizer-bypass as the download confirmation hero (issue #5819).
              The small logo gains nothing from /_next/image, and the optimizer
              indirection broke the logo in Safari (WebKit `Vary: Accept` cache
              mishandling). Matches the plain <img> the site header uses. */}
          <img
            src="/logo.png"
            alt=""
            width={44}
            height={44}
            className="rounded-xl"
          />
          <div>
            <h1 className="text-2xl font-semibold tracking-tight">
              {t(`${kind}.title`)}
            </h1>
            <p className="mt-1 text-[15px] text-muted">
              {t(`${kind}.intro`)}
            </p>
          </div>
        </div>

        {canOpen ? (
          <div className="mb-6 flex flex-wrap gap-3">
            <a
              href={href}
              className="inline-flex items-center rounded-full bg-foreground px-5 py-2.5 text-[15px] font-medium transition-opacity hover:opacity-85"
              style={{ color: "var(--background)", textDecoration: "none" }}
            >
              {t("open")}
            </a>
            <Link
              href={DOWNLOAD_CONFIRMATION_HREF}
              className="inline-flex items-center rounded-full border border-border px-5 py-2.5 text-[15px] font-medium transition-colors hover:bg-code-bg"
            >
              {t("download")}
            </Link>
          </div>
        ) : (
          <div className="mb-6 rounded-lg border border-border bg-code-bg px-4 py-3 text-[14px] text-muted">
            {errorMessage}
          </div>
        )}

        <div className="rounded-lg border border-border">
          <div className="border-b border-border px-4 py-3 text-[13px] font-medium text-muted">
            {t("nativeURL")}
          </div>
          <pre className="overflow-x-auto p-4 text-[13px] leading-relaxed">
            <code>{href}</code>
          </pre>
        </div>

        <p className="mt-5 text-[14px] leading-6 text-muted">
          {canOpen ? t(`${kind}.fallback`) : t("fixParams")}
        </p>

        <p className="mt-6 text-[14px] leading-6 text-muted">
          {t("examplePrefix")}{" "}
          <a
            href={definition.exampleHref}
            className="underline underline-offset-2 decoration-link-underline hover:decoration-foreground"
          >
            {t("exampleLink")}
          </a>
          .
        </p>
      </main>
    </div>
  );
}
