import { generateOpenAPIDocument } from "@/orpc/server/openapi";


export async function GET(): Promise<Response> {
  const document = await generateOpenAPIDocument();
  return Response.json(document);
}
