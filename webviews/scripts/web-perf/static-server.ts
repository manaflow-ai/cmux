// A static file server for webviews-ab.sh: `bun static-server.ts ROOT PORT`. No compression, as
// the app reads these files from its bundle; a directory path serves its index.html.
import path from "node:path";

const [root, port] = process.argv.slice(2);
if (!root || !port) throw new Error("usage: static-server.ts ROOT PORT");
const base = path.resolve(root);

Bun.serve({
  hostname: "127.0.0.1",
  port: Number(port),
  async fetch(request) {
    let rel = decodeURIComponent(new URL(request.url).pathname);
    if (rel.endsWith("/")) rel += "index.html";
    const file = path.resolve(base, `.${rel}`);
    if (!file.startsWith(base)) return new Response("forbidden", { status: 403 });
    const body = Bun.file(file);
    if (!(await body.exists())) return new Response("not found", { status: 404 });
    const type = /\.m?js$/.test(file) ? "text/javascript" : body.type;
    return new Response(body, { headers: { "content-type": type } });
  },
});
console.log(`serving ${base} on ${port}`);
