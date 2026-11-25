import {
  BrowserNightlyDownloadError,
  resolveBrowserNightlyDownload,
  type BrowserNightlyDownloadDependencies,
} from "@/app/lib/browser-nightly-download";
import {
  isPlatformDownloadAvailable,
  type DownloadPlatform,
} from "@/app/lib/download";

/**
 * Feed platforms whose website downloads follow a cmux.com release switch.
 * Linux is waitlist-only, so its direct links stop resolving here; installed
 * copies update from the signed feed and never come through this route.
 */
const GATED_FEED_PLATFORMS: Readonly<Record<string, DownloadPlatform>> = {
  "linux-x64": "linux",
};


interface BrowserNightlyRouteParameters {
  readonly platform: string;
  readonly artifact: string;
}

export async function GET(
  _request: Request,
  context: { params: Promise<BrowserNightlyRouteParameters> },
): Promise<Response> {
  const parameters = await context.params;
  // The release switch is checked before any feed request, so a waitlist-only
  // platform never reaches GitHub.
  const gated = GATED_FEED_PLATFORMS[parameters.platform];
  if (gated && !isPlatformDownloadAvailable(gated)) {
    return jsonError("browser_download_unavailable", 404);
  }
  return handleBrowserNightlyDownloadRequest(parameters);
}

/** Exported separately so route behavior can be tested without live GitHub I/O. */
export async function handleBrowserNightlyDownloadRequest(
  parameters: BrowserNightlyRouteParameters,
  dependencies: BrowserNightlyDownloadDependencies = {},
): Promise<Response> {
  try {
    const resolution = await resolveBrowserNightlyDownload(
      parameters.platform,
      parameters.artifact,
      dependencies,
    );
    return new Response(null, {
      status: 307,
      headers: {
        "Cache-Control":
          "public, max-age=0, s-maxage=300, stale-while-revalidate=3600",
        Location: resolution.url,
        "X-Cmux-Browser-Version": resolution.version,
        "X-Content-Type-Options": "nosniff",
      },
    });
  } catch (error) {
    if (error instanceof BrowserNightlyDownloadError) {
      if (error.code === "not_found") {
        return jsonError("browser_download_not_found", 404);
      }
      if (error.code === "unavailable") {
        return jsonError("browser_download_unavailable", 404);
      }
      return jsonError("browser_download_feed_unavailable", 502);
    }
    return jsonError("browser_download_feed_unavailable", 502);
  }
}

function jsonError(error: string, status: number): Response {
  return Response.json(
    { error },
    {
      status,
      headers: {
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
      },
    },
  );
}
