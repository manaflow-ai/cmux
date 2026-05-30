import { type NextRequest, NextResponse } from "next/server";
import {
  buildLlmsText,
  resolveAgentPageVariant,
} from "../lib/agent-page-paths";
import {
  hasSensitiveCanonicalAccess,
  headersForCanonicalFetch,
} from "../lib/agent-page-canonical-fetch";
import { sameOriginRedirectUrl } from "../lib/agent-page-redirects";
import {
  headersForAgentPage,
  headersForLlmsTxt,
  localeFromCanonicalPath,
  markdownFromHtml,
  plainTextFromMarkdown,
} from "../lib/agent-page-markdown";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const CANONICAL_FETCH_TIMEOUT_MS = 5_000;

export async function GET(request: NextRequest) {
  const variant = resolveAgentPageVariant(
    request.headers.get("x-cmux-agent-page-path") ??
      request.nextUrl.searchParams.get("path"),
  );
  if (!variant) {
    return new NextResponse("Not found\n", { status: 404 });
  }

  const origin = request.nextUrl.origin;

  if (variant.kind === "llms") {
    return new NextResponse(buildLlmsText(origin), {
      headers: headersForLlmsTxt(),
    });
  }

  const htmlUrl = new URL(request.url);
  htmlUrl.pathname = variant.canonicalPath;
  htmlUrl.search = "";

  const canonicalFetchHeaders = headersForCanonicalFetch({
    requestHeaders: request.headers,
    searchParams: request.nextUrl.searchParams,
  });

  const htmlResponse = await fetchCanonicalHtml(htmlUrl, canonicalFetchHeaders);

  const contentType =
    htmlResponse?.headers.get("content-type")?.toLowerCase() ?? "";
  if (!htmlResponse || !htmlResponse.ok || !contentType.includes("text/html")) {
    return new NextResponse("Not found\n", { status: 404 });
  }

  const sourceUrl = canonicalUrlFromResponse(htmlResponse, htmlUrl);
  const markdown = markdownFromHtml({
    html: await htmlResponse.text(),
    sourceUrl,
  });
  const body =
    variant.format === "txt" ? plainTextFromMarkdown(markdown) : markdown;
  return new NextResponse(body, {
    headers: headersForAgentPage({
      canonicalUrl: sourceUrl,
      contentLanguage: localeFromCanonicalPath(new URL(sourceUrl).pathname),
      format: variant.format,
      privateResponse: hasSensitiveCanonicalAccess(canonicalFetchHeaders),
      varyAcceptLanguage: canonicalFetchHeaders.has("accept-language"),
    }),
  });
}

async function fetchCanonicalHtml(
  htmlUrl: URL,
  headers: Headers,
): Promise<Response | null> {
  let currentUrl = new URL(htmlUrl);

  for (let redirectCount = 0; redirectCount < 6; redirectCount += 1) {
    const controller = new AbortController();
    const timeout = setTimeout(
      () => controller.abort(),
      CANONICAL_FETCH_TIMEOUT_MS,
    );
    let response: Response;
    try {
      response = await fetch(currentUrl, {
        cache: "no-store",
        headers,
        redirect: "manual",
        signal: controller.signal,
      });
    } catch {
      return null;
    } finally {
      clearTimeout(timeout);
    }

    if (!isRedirectStatus(response.status)) {
      return response;
    }

    const nextUrl = sameOriginRedirectUrl({
      currentUrl,
      location: response.headers.get("location"),
      origin: htmlUrl.origin,
    });
    if (!nextUrl) {
      return response;
    }

    currentUrl = nextUrl;
  }

  return null;
}

function isRedirectStatus(status: number): boolean {
  return status >= 300 && status < 400;
}

function canonicalUrlFromResponse(response: Response, fallbackUrl: URL): string {
  if (!response.url) {
    return fallbackUrl.toString();
  }

  try {
    const url = new URL(response.url);
    url.hash = "";
    return url.toString();
  } catch {
    return fallbackUrl.toString();
  }
}
