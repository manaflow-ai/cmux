export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function upstreamErrorResponse(): Response {
  return json({ error: "upstream_error" }, 502);
}
