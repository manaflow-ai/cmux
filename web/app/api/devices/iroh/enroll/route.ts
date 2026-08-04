import { handleIrohEnrollment } from "../../../../../services/iroh/enrollment";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  return handleIrohEnrollment(request);
}
