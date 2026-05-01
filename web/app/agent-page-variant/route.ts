import { type NextRequest, NextResponse } from "next/server";
import {
  buildLlmsText,
  resolveAgentPageVariant,
} from "../lib/agent-page-paths";
import {
  headersForAgentPage,
  headersForLlmsTxt,
  localeFromCanonicalPath,
  markdownFromHtml,
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

  const htmlResponse = await fetch(htmlUrl, {
    cache: "no-store",
    headers: {
      accept: "text/html",
      "x-cmux-agent-page-variant": "canonical-html",
    },
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

  return new NextResponse(markdown, {
    headers: headersForAgentPage({
      canonicalUrl: sourceUrl,
      contentLanguage: localeFromCanonicalPath(new URL(sourceUrl).pathname),
      format: variant.format,
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
