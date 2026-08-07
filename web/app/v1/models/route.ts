import { proxyCodexModels } from "@/services/coderouter/codexProxy";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

export async function GET(request: Request): Promise<Response> {
  return await proxyCodexModels(request);
}
