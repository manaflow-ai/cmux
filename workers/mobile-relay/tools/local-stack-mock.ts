// Minimal Stack API stand-in for LOCAL relay testing only. Answers every
// /api/v1/users/me with one fixed user id, so `wrangler dev --local` can
// verify connects without real credentials. Never deploy anything pointing
// at this: it accepts any token by design.

const port = Number(process.env.PORT ?? 8899);
Bun.serve({
  port,
  fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/users/me") {
      return Response.json({ id: "local-latency-user" });
    }
    return Response.json({ error: "not_found" }, { status: 404 });
  },
});
console.log(`local stack mock on http://127.0.0.1:${port} (any token verifies as local-latency-user)`);
