import {
  resolveNextNightlyDownload,
  type NextNightlyDownloadDependencies,
} from "@/app/lib/next-nightly-download";
import { CMUX_NEXT_NIGHTLY_DMG_URL } from "@/app/lib/nightly-downloads";

/**
 * cmux.com's cmux NEXT download: a redirect to the update feed's newest DMG.
 *
 * The app offers the feed's newest item as its update, so a download resolved
 * from the same feed is never a build behind it. The edge keeps an answer for
 * 15 s, so a build the feed just published reaches downloads within seconds.
 */
export async function GET(): Promise<Response> {
  return handleNextNightlyDownloadRequest();
}

/** Exported separately so route behavior can be tested without live feed I/O. */
export async function handleNextNightlyDownloadRequest(
  dependencies: NextNightlyDownloadDependencies = {},
): Promise<Response> {
  try {
    const resolution = await resolveNextNightlyDownload(dependencies);
    return redirect(resolution.url, "public, max-age=0, s-maxage=15, stale-while-revalidate=45", {
      "X-Cmux-Build": resolution.build,
    });
  } catch {
    // A download that may trail the feed beats no download; nothing caches it.
    return redirect(CMUX_NEXT_NIGHTLY_DMG_URL, "no-store");
  }
}

function redirect(location: string, cacheControl: string, extra: Record<string, string> = {}): Response {
  return new Response(null, {
    status: 307,
    headers: {
      "Cache-Control": cacheControl,
      Location: location,
      "X-Content-Type-Options": "nosniff",
      ...extra,
    },
  });
}
