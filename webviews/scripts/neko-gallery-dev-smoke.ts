// Run through cmux-ci from webviews/. Verify imported gallery art under fs.strict.
import { createServer } from "vite-plus";

const server = await createServer({ configFile: "vite.config.gallery-dev.ts", server: { port: 0 } });
try {
  await server.listen();
  const transformed = await server.transformRequest("/src/agent-session/acpmux/icons/NekoIconGallery.gallery.tsx");
  const address = server.httpServer?.address();
  if (!transformed || !address || typeof address === "string") throw new Error("Gallery server did not start");
  const origin = `http://127.0.0.1:${address.port}`;
  const urls = [...transformed.code.matchAll(/from\s+["']([^"']+\.svg[^"']*)["']/g)].map((match) => match[1]);
  if (urls.length !== 12) throw new Error(`Expected 12 SVG imports, got ${urls.length}`);
  for (const url of urls) {
    const module = await fetch(new URL(url, origin));
    if (!module.ok) throw new Error(`SVG module ${module.status}: ${url}`);
    const source = await module.text();
    // Vite can inline small SVGs as a data URL containing literal single quotes.
    // Decode the entire JSON string instead of stopping at an embedded SVG quote.
    const encoded = source.match(/^export default (".*")\s*;?\s*$/m)?.[1];
    if (!encoded) throw new Error(`Missing SVG export: ${url}`);
    const asset = JSON.parse(encoded) as string;
    const response = await fetch(new URL(asset, origin));
    if (!response.ok || !(await response.text()).includes("<svg")) throw new Error(`SVG asset denied: ${url}`);
  }
  console.log("gallery-dev serves all 12 imported candidate SVGs with fs.strict");
} finally {
  await server.close();
}
