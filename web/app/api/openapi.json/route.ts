import { generateOpenAPIDocument } from "@/orpc/server/openapi";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET(): Promise<Response> {
  const document = await generateOpenAPIDocument();
  return Response.json(document);
}
