import { type NextRequest, NextResponse } from "next/server";
import {
  buildLlmsText,
  resolveAgentPageVariant,
} from "../lib/agent-page-paths";
import { headersForCanonicalFetch } from "../lib/agent-page-canonical-fetch";
import {
  headersForAgentPage,
  headersForLlmsTxt,
  localeFromCanonicalPath,
  markdownFromHtml,
  plainTextFromMarkdown,
} from "../lib/agent-page-markdown";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

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

  const htmlResponse = await fetch(htmlUrl, {
    cache: "no-store",
    headers: canonicalFetchHeaders,
    redirect: "follow",
  });

  if (
    !htmlResponse.ok ||
    !htmlResponse.headers.get("content-type")?.includes("text/html")
  ) {
    return new NextResponse("Not found\n", { status: 404 });
  }

  const sourceUrl = canonicalUrlFromResponse(htmlResponse, htmlUrl);
  const markdown = markdownFromHtml({
    html: await htmlResponse.text(),
    origin,
    sourceUrl,
  });
  const body =
    variant.format === "txt" ? plainTextFromMarkdown(markdown) : markdown;

  return new NextResponse(body, {
    headers: headersForAgentPage({
      canonicalUrl: sourceUrl,
      contentLanguage: localeFromCanonicalPath(new URL(sourceUrl).pathname),
      format: variant.format,
      privateResponse:
        canonicalFetchHeaders.has("authorization") ||
        canonicalFetchHeaders.has("cookie"),
      varyAcceptLanguage: canonicalFetchHeaders.has("accept-language"),
    }),
  });
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
