import { browserOpenGraphImageResponse } from "@/app/lib/browser-open-graph-image";

export const runtime = "nodejs";
export const dynamic = "force-static";

export function GET(): Promise<Response> {
  return browserOpenGraphImageResponse();
}
