import { recentlyModifiedUrls, submitIndexNowUrls } from "../../../lib/indexnow";
import sitemap from "../../../sitemap";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  const triggerSecret = process.env.CRON_SECRET?.trim();
  if (
    !triggerSecret ||
    request.headers.get("authorization") !== `Bearer ${triggerSecret}`
  ) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  const urls = recentlyModifiedUrls(sitemap(), new Date());
  if (urls.length === 0) {
    return Response.json({ ok: true, submitted: 0 });
  }

  try {
    const status = await submitIndexNowUrls(urls);
    return Response.json({ ok: true, submitted: urls.length, status });
  } catch (error) {
    console.error("indexnow.submit_failed", error);
    return Response.json({ error: "indexnow_submit_failed" }, { status: 502 });
  }
}
