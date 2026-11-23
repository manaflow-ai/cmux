// TEMPORARY (cmux#50535 bench instrumentation, removed before land): on the graceful-swap fleet bench
// only (its dev server's transform cache lies under .../gsw/scratch/), every page's HMR events and the
// server's own log go to gsw/latency/gsw-dev-probe.ndjson, which the bench artifact carries.
import fs from "node:fs";
import path from "node:path";
import type { Plugin } from "vite-plus";
import { devEntrySrc } from "./devEntrySrc";

function probeFile(): string | null {
  const cache = process.env.CMUX_VITE_TRANSFORM_CACHE ?? "";
  if (!cache.includes("/gsw/scratch/")) return null;
  const gsw = cache.slice(0, cache.indexOf("/gsw/scratch/") + "/gsw".length);
  return path.join(gsw, "latency", "gsw-dev-probe.ndjson");
}

export function gswProbe(webviewsRoot: string): Plugin {
  const file = probeFile();
  const entry = path.join(webviewsRoot, "src/devkit/gswProbe.dev.ts");
  let src = "/src/devkit/gswProbe.dev.ts";
  const write = (record: Record<string, unknown>) => {
    if (!file) return;
    try {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.appendFileSync(file, `${JSON.stringify({ server_at: Date.now(), ...record })}\n`);
    } catch {}
  };
  return {
    name: "cmux-dev-gsw-probe",
    apply: "serve",
    configResolved(config) {
      src = devEntrySrc(config, entry);
      if (!file) return;
      const logger = config.logger;
      for (const level of ["info", "warn", "error"] as const) {
        const original = logger[level].bind(logger);
        logger[level] = (message: string, options?: never) => {
          write({ kind: "server-log", level, message: String(message).slice(0, 600) });
          original(message, options);
        };
      }
    },
    configureServer(server) {
      if (!file) return;
      write({ kind: "server-start" });
      server.ws.on("connection", () => write({ kind: "ws-connection" }));
      server.ws.on("gsw:probe", (data: Record<string, unknown>) => write({ kind: "page", ...data }));
      server.watcher.on("change", (changed: string) => write({ kind: "watch-change", file: changed }));
    },
    handleHotUpdate({ file: changed, modules, timestamp }) {
      write({
        kind: "hot-update",
        file: changed,
        timestamp,
        modules: modules.map((m) => m.url).slice(0, 20),
      });
    },
    transformIndexHtml() {
      if (!file) return [];
      return [{ tag: "script", attrs: { type: "module", src }, injectTo: "head-prepend" }];
    },
  };
}
