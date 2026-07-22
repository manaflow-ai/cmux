import { openGraphImageResponse } from "@/app/lib/open-graph-image";
import { routing } from "@/i18n/routing";

export const runtime = "nodejs";
export const dynamic = "force-static";

export function GET(): Promise<Response> {
  return openGraphImageResponse(routing.defaultLocale);
}
