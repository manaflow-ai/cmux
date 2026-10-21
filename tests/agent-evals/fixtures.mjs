// Local fixture site for the app-tier agent evals: no live web, fixed content,
// and a record of every form post so the website-form task is graded on what
// the server received, not on what the agent says it did.

const page = (title, body) =>
  `<!doctype html><html><head><meta charset="utf-8"><title>${title}</title></head><body><h1>${title}</h1>${body}</body></html>`;

export const PAGES = Object.freeze({
  "/": page("cmux eval fixture", "<p>Fixture home. EVAL_FIXTURE_HOME</p>"),
  "/signup": page(
    "Sign up",
    `<form method="post" action="/signup">
       <label>Full name <input name="name" autocomplete="off"></label>
       <label>Plan <select name="plan"><option value="free">Free</option><option value="pro">Pro</option><option value="team">Team</option></select></label>
       <button type="submit">Create account</button>
     </form>`,
  ),
  "/order": page(
    "Order 1042",
    `<table><tr><td>Keyboard</td><td>$1,049.00</td></tr><tr><td>Cable</td><td>$35.50</td></tr><tr><td>Shipping</td><td>$200.00</td></tr>
     <tr><th>Total</th><th id="total">$1,284.50</th></tr></table>`,
  ),
  "/a": page("Research A: terminal latency", "<p>Paper A.</p>"),
  "/b": page("Research B: input pipelines", "<p>Paper B.</p>"),
  "/c": page("Research C: frame pacing", "<p>Paper C.</p>"),
});

export const PLAN_MD = "# Plan\n\n- [ ] Ship agent evals\n- [ ] Baseline every agent\n\nEVAL_MARKDOWN_OK\n";

/** Starts the fixture server on a free port. Returns { url, posts, stop }. */
export function startFixtureServer() {
  const posts = [];
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(req) {
      const url = new URL(req.url);
      if (req.method === "POST") {
        const form = Object.fromEntries((await req.formData()).entries());
        posts.push({ path: url.pathname, body: form });
        return new Response(page("Thanks", `<p>Welcome, ${String(form.name ?? "").replace(/[<>&]/g, "")}.</p>`), {
          headers: { "content-type": "text/html" },
        });
      }
      const html = PAGES[url.pathname];
      return html ? new Response(html, { headers: { "content-type": "text/html" } }) : new Response("not found", { status: 404 });
    },
  });
  return { url: `http://127.0.0.1:${server.port}`, posts, stop: () => server.stop(true) };
}

/** True when the server got exactly one matching post (case-insensitive values). */
export function serverReceived(posts, { path, body }) {
  const norm = (v) => String(v ?? "").trim().toLowerCase();
  const hits = posts.filter((p) => p.path === path && Object.entries(body).every(([k, v]) => norm(p.body[k]) === norm(v)));
  return hits.length === 1 && posts.filter((p) => p.path === path).length === 1;
}
