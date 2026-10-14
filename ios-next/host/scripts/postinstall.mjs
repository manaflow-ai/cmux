// node-pty ships prebuilt spawn-helper binaries without the executable bit,
// which makes every spawn fail with "posix_spawnp failed". Fix it in place.
import { chmodSync, existsSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
try {
  const root = dirname(require.resolve("node-pty/package.json"));
  for (const sub of ["prebuilds", "build/Release"]) {
    const dir = join(root, sub);
    if (!existsSync(dir)) continue;
    const walk = (d) => {
      for (const e of readdirSync(d, { withFileTypes: true })) {
        const p = join(d, e.name);
        if (e.isDirectory()) walk(p);
        else if (e.name === "spawn-helper") chmodSync(p, 0o755);
      }
    };
    walk(dir);
  }
} catch (err) {
  console.warn("cmux-next-host postinstall: could not fix node-pty spawn-helper:", err?.message ?? err);
}
