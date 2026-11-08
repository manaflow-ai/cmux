// Serve the real Freestyle forward-auth route standalone, so the Freestyle edge
// can be pointed at a development machine through any HTTPS tunnel and the
// edge <-> cmux contract can be exercised without deploying the web app.
//
//   SKIP_ENV_VALIDATION=1 DATABASE_URL=... \
//   CMUX_VM_PUBLICATION_FORWARD_AUTH_SECRET=... \
//   CMUX_VM_PUBLICATION_AUTH_ORIGIN=https://<tunnel> \
//   bun --env-file=/dev/null run scripts/vm-publication-forward-auth-server.ts
//
// `/cloud/access` answers with a placeholder page (the Next.js page needs Stack
// Auth); every request and decision is logged.
import { GET as forwardAuth } from "../app/api/freestyle/forward-auth/route";

// The web package's tsconfig does not load Bun's ambient types; this script is
// Bun-only, so type the one global it needs here.
declare const Bun: {
  serve(options: {
    port: number;
    fetch(request: Request): Response | Promise<Response>;
  }): unknown;
};

const port = Number(process.env.PORT ?? 3000);
const log = (line: string) => console.log(`[forward-auth] ${new Date().toISOString()} ${line}`);

Bun.serve({
  port,
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/api/freestyle/forward-auth") {
      const forwarded = [
        "x-forwarded-method",
        "x-forwarded-proto",
        "x-forwarded-host",
        "x-forwarded-uri",
        "x-freestyle-tls-rule-id",
      ].map((name) => `${name}=${request.headers.get(name) ?? "-"}`).join(" ");
      const response = await forwardAuth(request);
      log(`${forwarded} cookie=${request.headers.has("cookie") ? "yes" : "no"} -> ${response.status}${response.headers.get("location") ? ` location=${response.headers.get("location")}` : ""}`);
      return response;
    }
    if (url.pathname === "/cloud/access") {
      log(`access page transaction=${url.searchParams.get("transaction")?.slice(0, 8) ?? "-"}…`);
      return new Response(
        `<!doctype html><title>cmux sign-in (stand-in)</title><body style="font-family:system-ui;padding:2rem"><h1>cmux sign-in would render here</h1><p>The Freestyle edge redirected this browser to the cmux access page with transaction <code>${url.searchParams.get("transaction") ?? ""}</code>. In the deployed app this page signs you in with Stack Auth and sends you back to the site.</p></body>`,
        { status: 200, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } },
      );
    }
    log(`${request.method} ${url.pathname} -> 404`);
    return new Response("not found", { status: 404 });
  },
});
log(`listening on :${port}; auth origin ${process.env.CMUX_VM_PUBLICATION_AUTH_ORIGIN ?? "(unset)"}`);
