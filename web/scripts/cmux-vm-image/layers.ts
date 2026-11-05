/**
 * The layered bake (bake.ts --layered): the image as a chain of snapshots, each keyed by a hash of its own
 * inputs, the way a Dockerfile's layer cache or a content-addressed build graph (BuildKit, Dagger, Nix) splits a
 * build. Only a layer whose key changed rebuilds; every layer above it rebuilds on top.
 *
 *   system  apt, runtimes, system config, units: today's full bake from freestyle/ubuntu-sm. Key: the lock
 *           without its programs, the bake flags, and the git blobs of every file the bake reads.
 *   agents  the agent CLIs and tools in the store (claude, codex, gh, chrome-for-testing, ...): a clone of
 *           system with the changed store entries swapped in. Key: system key + those program pins.
 *   app     cmux-tui and its hook: a clone of agents with the new entries, the steps that read cmux-tui (wiring,
 *           host config, daemon start and identify, model plane) and the finalize. Not cached: one per run.
 *           It compiles nothing: the binaries are the ones CI published for that commit
 *           (files.cmux.com/cmux-tui/<commit>/, pinned by pin-cmux-tui.ts), checked against the lock's sha256.
 *
 * Freestyle snapshots carry memory, so a layer is "boot the parent, apply, snapshot", not a union filesystem
 * (Fly's "Docker without Docker" turns OCI layers into one rootfs for the same reason). The store makes a layer's
 * apply small: an entry is named by its sha256, so a pin that did not change is already on disk.
 *
 * The full bake (bake.ts without --layered, the weekly and manual run) stays the source of truth, so the image
 * stays reproducible from the lock alone.
 */
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { DEVBOX_WORK_HOME } from "../../services/vms/images/workUser";
import { CURRENT_BIN, STORE_DIR } from "./lock";

/** Lock programs that belong to the app layer; every other program belongs to the agents layer. */
export const APP_PROGRAMS = ["cmux-tui", "cmux-tui-hook"] as const;

export type LayerName = "system" | "agents";

/** Name prefix of a cached layer's snapshot (the slug is `<prefix><key16>`). */
export const LAYER_PREFIX: Record<LayerName, string> = { system: "cmuxnp-dev-vmimg-sys-", agents: "cmuxnp-dev-vmimg-agt-" };

export const isAppProgram = (name: string) => (APP_PROGRAMS as readonly string[]).includes(name);

/**
 * Files whose content the system layer depends on, besides the lock: the bake, its guest files and every image
 * source it reads. Over-inclusive on purpose: an extra rebuild costs one full bake, a missed input ships a stale
 * layer.
 */
export const BASE_INPUT_PATHS = [
  "images/cmux-vm",
  "web/scripts/cmux-vm-image",
  "web/scripts/devbox-image-common.ts",
  "web/services/vms",
  "web/services/coderouter/vmGuestEnv.ts",
] as const;

/** Files in BASE_INPUT_PATHS that are not inputs: the lock is keyed by its parts, and docs and tests change nothing. */
export function isBaseInput(file: string): boolean {
  if (file === "images/cmux-vm/inputs.lock.json") return false;
  if (file.startsWith("images/cmux-vm/channels/")) return false;
  if (file.endsWith(".md") || file.includes("/tests/") || /\.test\.ts$/.test(file)) return false;
  return true;
}

const canon = (v: unknown): unknown =>
  Array.isArray(v)
    ? v.map(canon)
    : v && typeof v === "object"
      ? Object.fromEntries(Object.keys(v as object).sort().map((k) => [k, canon((v as Record<string, unknown>)[k])]))
      : v;

type LockShape = { programs?: Array<{ name: string }> };

/** The lock as the system layer sees it: no programs, keys sorted. */
export function systemLockText(lockText: string): string {
  return JSON.stringify(canon({ ...(JSON.parse(lockText) as LockShape), programs: [] }));
}

/** The agents layer's programs (every program but the app's), sorted by name, keys sorted. */
export function agentProgramsText(lockText: string): string {
  const programs = ((JSON.parse(lockText) as LockShape).programs ?? []).filter((p) => !isAppProgram(p.name));
  return JSON.stringify(canon([...programs].sort((a, b) => a.name.localeCompare(b.name))));
}

/** `git ls-tree -r` lines (mode, type, blob, path) of the inputs at `rev`, sorted. */
export function baseInputTree(root: string, rev = "HEAD"): string {
  const r = spawnSync("git", ["-C", root, "ls-tree", "-r", rev, "--", ...BASE_INPUT_PATHS], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`git ls-tree for the layer inputs failed: ${r.stderr}`);
  return r.stdout.split("\n").filter((l) => l && isBaseInput(l.slice(l.indexOf("\t") + 1))).sort().join("\n");
}

const sha = (...parts: string[]) => {
  const h = createHash("sha256");
  for (const part of parts) h.update(part).update("\n\0");
  return h.digest("hex");
};

/** Both cached layers' keys. The agents key folds in the system key, so a system rebuild rebuilds agents too. */
export function layerKeys(lockText: string, flags: readonly string[], inputTree: string): Record<LayerName, string> {
  const system = sha("cmux-vm-system-v1", systemLockText(lockText), `flags ${[...flags].sort().join(" ")}`, inputTree);
  return { system, agents: sha("cmux-vm-agents-v1", system, agentProgramsText(lockText)) };
}

/** A cached layer's snapshot name and slug. Fits the 41-character tag limit of `cmuxnp-dev-vmimg-<tag>`. */
export const layerName = (layer: LayerName, key: string) => `${LAYER_PREFIX[layer]}${key.slice(0, 16)}`;

/**
 * First step of an overlay layer on a parent clone: no self-update during the bake (the snapshot carries the
 * lock's build; cmux#36185's marker), the apt sources as the parent's finalize left them (so finalize's restore
 * is a no-op), and the store entries the profile links for `bins` now, recorded so the prune can drop the ones
 * the new profile no longer names.
 */
export function overlayPrepareCommand(bins: readonly string[]): string {
  return [
    "mkdir -p /etc/cmux && touch /etc/cmux/no-self-update",
    "cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/ubuntu.sources.live",
    `for n in ${bins.join(" ")}; do readlink ${CURRENT_BIN}/$n 2>/dev/null | sed -nE 's#^(${STORE_DIR}/[^/]+)/.*#\\1#p'; done | sort -u > /root/layer-old-entries`,
    "echo parent $(cat /etc/cmux/image-stamp 2>/dev/null)",
    "wc -l < /root/layer-old-entries",
  ].join(" && ");
}

/** Install one store entry unless its sha256 is already on disk (an unchanged pin costs nothing). */
export function cachedInstallCommand(entry: string, install: string, name: string): string {
  return `if [ -d ${entry} ]; then echo "store ${name} cached"; else ${install}; fi`;
}

/** After the new profile: remove recorded entries no profile link or other symlink under the image's roots names. */
export function overlayPruneCommand(): string {
  return [
    `in_use="$(for l in ${CURRENT_BIN}/*; do readlink "$l"; done)"`,
    'while IFS= read -r e; do [ -n "$e" ] || continue; case "$in_use" in *"$e/"*) echo "keep $e"; continue ;; esac; ' +
      'if [ -n "$(find /opt /usr/local /etc /root /home -xdev -lname "$e/*" -print -quit 2>/dev/null)" ]; then echo "keep $e (linked)"; continue; fi; ' +
      'chmod -R u+w "$e" && rm -rf "$e" && echo "pruned $e"; done < /root/layer-old-entries',
    "rm -f /root/layer-old-entries",
  ].join("; ");
}

/** The image's package names, written at finalize: the baseline a person's own layer is measured against. */
export const IMAGE_PACKAGES_PATH = "/etc/cmux/image-packages.txt";

/** Finalize: record the image's apt, npm-global and store program names, one `kind name` per line, sorted. */
export function imagePackagesCommand(): string {
  return [
    `{ dpkg-query -W -f='apt \${Package}\\n'; npm ls -g --depth=0 --parseable 2>/dev/null | sed -n 's#.*/node_modules/#npm #p'; ls ${CURRENT_BIN} | sed 's#^#bin #'; } | LC_ALL=C sort -u > ${IMAGE_PACKAGES_PATH}`,
    `chmod 0644 ${IMAGE_PACKAGES_PATH}`,
    `wc -l < ${IMAGE_PACKAGES_PATH}`,
  ].join(" && ");
}

/**
 * The first step of a person's own layer (plans/cloud/images-per-user.md in cmuxterm-hq): on their machine,
 * the package names they added since the image, in the same `kind name` form: apt, npm and bun globals, uv
 * and pipx tools, cargo installs. Names only, no versions, paths or arguments; nothing sends it anywhere; the
 * per-user layer reads it only under the opt-in usage setting, off by default.
 */
export function userAdditionsCommand(home = DEVBOX_WORK_HOME): string {
  const now = [
    "dpkg-query -W -f='apt ${Package}\\n'",
    "npm ls -g --depth=0 --parseable 2>/dev/null | sed -n 's#.*/node_modules/#npm #p'",
    `ls ${home}/.bun/install/global/node_modules 2>/dev/null | sed 's#^#bun #'`,
    `ls ${home}/.local/share/uv/tools 2>/dev/null | sed 's#^#uv #'`,
    `ls ${home}/.local/pipx/venvs 2>/dev/null | sed 's#^#pipx #'`,
    `ls ${home}/.cargo/bin 2>/dev/null | sed 's#^#cargo #'`,
  ];
  return `{ ${now.join("; ")}; } | LC_ALL=C sort -u | LC_ALL=C comm -13 ${IMAGE_PACKAGES_PATH} -`;
}
