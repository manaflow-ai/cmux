import { handleIrohEnrollmentTokenMint } from "../../../../../services/iroh/enrollment";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  return handleIrohEnrollmentTokenMint(request);
}
