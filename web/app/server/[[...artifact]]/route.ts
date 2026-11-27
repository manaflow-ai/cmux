import { serverDownloadUrl } from "../../lib/server-download";

type Context = { params: Promise<{ artifact?: string[] }> };

export async function GET(_request: Request, context: Context): Promise<Response> {
  const { artifact = [] } = await context.params;
  const location = serverDownloadUrl(artifact);
  const headers = {
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  };
  return location
    ? new Response(null, { status: 307, headers: { ...headers, Location: location } })
    : Response.json({ error: "server_download_not_found" }, { status: 404, headers });
}

export async function HEAD(request: Request, context: Context): Promise<Response> {
  const response = await GET(request, context);
  return new Response(null, { status: response.status, headers: response.headers });
}
