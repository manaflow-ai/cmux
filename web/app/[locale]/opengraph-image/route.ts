import { openGraphImageResponse } from "@/app/lib/open-graph-image";

export const runtime = "nodejs";
export const dynamic = "force-static";

export async function GET(
  _request: Request,
  context: { params: Promise<{ locale: string }> },
): Promise<Response> {
  const { locale } = await context.params;
  return openGraphImageResponse(locale);
}
