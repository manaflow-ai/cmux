export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function upstreamErrorResponse(error?: unknown): Response {
  const statusCode = typeof (error as { statusCode?: unknown })?.statusCode === "number"
    ? (error as { statusCode: number }).statusCode
    : undefined;
  return json(
    statusCode === undefined
      ? { error: "upstream_error" }
      : { error: "upstream_error", upstream_status: statusCode },
    502,
  );
}
