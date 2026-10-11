// The live gallery: the gallery alone (src/gallery) on a dev server with hot reload, for a host that
// publishes it to the tailnet (cmuxterm-hq scripts/gallery-live.sh: /live/ follows feat-cmux-next,
// /wt/<name>/ a pushed branch). `bun run gallery:dev` serves it at http://127.0.0.1:4210/gallery/.
//
// It is NOT `bun run dev`: none of that server's other hosts (the diff sidecar, the markdown and
// code editors, whose routes read and write files in the home folder) are loaded, and Vite serves
// files from webviews/ only (fs.strict). It binds loopback; the host's router fronts it.
//
// Env (all optional):
//   CMUX_GALLERY_BASE          the URL prefix, also every module URL's (default /gallery/)
//   CMUX_GALLERY_DEV_PORT      the loopback port (default 4210)
//   CMUX_GALLERY_PUBLIC_PORT   the HTTPS port the browser reaches (tailscale serve); the HMR socket
//                              then connects with wss to that port, through the same proxy
//   CMUX_GALLERY_ALLOWED_HOSTS comma-separated Host names besides localhost (the tailnet name)
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { PluginOption } from "vite-plus";
import base from "./vite.config";
import { galleryHost, galleryModules } from "./dev-server/galleryHost";
import { galleryLive } from "./dev-server/galleryLive";
import { cmuxDevServer } from "./dev-server/plugins";

const webviewsRoot = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.join(webviewsRoot, "..");
const urlBase = process.env.CMUX_GALLERY_BASE ?? "/gallery/";
if (!/^\/([a-z0-9._-]+\/)+$/i.test(urlBase)) throw new Error(`CMUX_GALLERY_BASE must look like /live/, not ${urlBase}`);
const publicPort = Number(process.env.CMUX_GALLERY_PUBLIC_PORT) || undefined;
const allowedHosts = (process.env.CMUX_GALLERY_ALLOWED_HOSTS ?? "").split(",").filter(Boolean);

/** `bun run dev`'s surfaces, which this server leaves out. */
const devServerPlugins = new Set(cmuxDevServer().map((plugin) => plugin.name));
const named = (plugin: PluginOption): plugin is { name: string } =>
  Boolean(plugin && typeof plugin === "object" && "name" in plugin);
const plugins = [base.plugins ?? []].flat(Infinity as 1) as PluginOption[];

export default {
  ...base,
  base: urlBase,
  plugins: [
    ...plugins.filter((plugin) => !(named(plugin) && devServerPlugins.has(plugin.name))),
    galleryModules(),
    // The shell at the base itself: /live/ is the gallery, /live/frame.html a stage.
    galleryHost({ mount: urlBase }),
    galleryLive({ webviewsRoot, repoRoot }),
  ],
  server: {
    host: "127.0.0.1",
    port: Number(process.env.CMUX_GALLERY_DEV_PORT) || 4210,
    strictPort: true,
    allowedHosts,
    fs: { strict: true, allow: [webviewsRoot] },
    // Behind tailscale serve the page is https://<host>:<public port>/<base>; the socket goes there too.
    ws: publicPort ? { protocol: "wss", clientPort: publicPort } : {},
    hmr: { overlay: true },
  },
};
