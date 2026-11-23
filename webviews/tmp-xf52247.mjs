const root = process.argv[2];
const { createServer } = await import("vite");
const server = await createServer({ root, configFile: root + "/vite.config.ts", server: { middlewareMode: true, hmr: false, ws: false }, optimizeDeps: { noDiscovery: true, include: [] }, logLevel: "error" });
const r = await server.transformRequest("/src/agent-session/acpmux/App.tsx");
const fs = await import("node:fs");
fs.writeFileSync(process.argv[3], r.code);
await server.close();
