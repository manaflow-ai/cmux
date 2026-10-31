// The dev server's stand-in for the app's `link.favicons` (AgentPaneSiteIcons.swift), so the agent
// pane's `?mock` page shows real site icons in a plain browser. Same rules as the app, in Node: a
// public host name only, asked of the favicon service T3 Code uses, over https, every address of
// every hop public, at most 3 redirects, 64 KiB, 5 s, an image type, no cookies or referrer. The
// app also redraws the icon as a PNG; here the bytes go back as they came, and Node's fetch looks
// the name up again after the check (the app pins the checked address): fine for a loopback dev
// server, not a pattern for shipped code. Answers are kept per host for the server's life (at most
// 256).
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";

const MAX_BYTES = 64 << 10;
const TIMEOUT_MS = 5_000;
const MAX_REDIRECTS = 3;
const MAX_HOSTS = 32;
const MAX_KEPT = 256;
const cache = new Map<string, Promise<string | null>>();

const PRIVATE_SUFFIX =
  /(?:^|\.)(?:localhost|local|internal|intranet|corp|private|home|lan|alt|test|example|invalid|onion)$/;
const INTERNAL_LABEL = /(?:^|\.)(?:corp|internal|intranet)\./;

/// `host` as the service is asked it, or undefined when it is not a public DNS name.
export function faviconHost(host: string): string | undefined {
  const name = host.toLowerCase().replace(/\.$/, "");
  if (name.length > 253 || isIP(name) || PRIVATE_SUFFIX.test(name) || INTERNAL_LABEL.test(name)) return undefined;
  const labels = name.split(".");
  if (labels.length < 2 || labels.some((label) => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label)))
    return undefined;
  if (!/^(?:[a-z]{2,63}|xn--[a-z0-9-]+)$/.test(labels.at(-1)!)) return undefined;
  return name;
}

function isPublicAddress(address: string): boolean {
  if (isIP(address) === 4) {
    const [a, b] = address.split(".").map(Number) as [number, number];
    return !(
      a === 0 ||
      a === 10 ||
      a === 127 ||
      a >= 224 ||
      (a === 100 && b >= 64 && b <= 127) ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168) ||
      (a === 198 && (b === 18 || b === 19))
    );
  }
  const v6 = address.toLowerCase();
  if (v6.startsWith("::ffff:")) return isPublicAddress(v6.slice(7));
  return !(v6 === "::" || v6 === "::1" || /^f[cd]/.test(v6) || /^fe[89ab]/.test(v6) || v6.startsWith("ff"));
}

async function fetchIcon(host: string): Promise<string | null> {
  let url = new URL("https://www.google.com/s2/favicons");
  url.searchParams.set("domain", host);
  url.searchParams.set("sz", "32");
  const deadline = AbortSignal.timeout(TIMEOUT_MS);
  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    if (url.protocol !== "https:" || url.username || url.password || isIP(url.hostname)) return null;
    const addresses = await lookup(url.hostname, { all: true }).catch(() => []);
    if (!addresses.length || !addresses.every((entry) => isPublicAddress(entry.address))) return null;
    const response = await fetch(url, {
      redirect: "manual",
      signal: deadline,
      credentials: "omit",
      referrerPolicy: "no-referrer",
      headers: { accept: "image/*" },
    }).catch(() => undefined);
    if (!response) return null;
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) return null;
      url = new URL(location, url);
      continue;
    }
    const type = (response.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
    // The page takes only a PNG (siteIcons.ts), which is what the service sends.
    if (!response.ok || type !== "image/png") return null;
    const length = Number(response.headers.get("content-length") ?? 0);
    if (length > MAX_BYTES) return null;
    const body = await readCapped(response);
    if (!body?.length) return null;
    return `data:image/png;base64,${body.toString("base64")}`;
  }
  return null;
}

/// The body, read until it passes MAX_BYTES (then undefined), so a large answer is never held whole.
async function readCapped(response: Response): Promise<Buffer | undefined> {
  const reader = response.body?.getReader();
  if (!reader) return undefined;
  const parts: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read().catch(() => ({ done: true, value: undefined }));
    if (done || !value) break;
    size += value.length;
    if (size > MAX_BYTES) {
      void reader.cancel();
      return undefined;
    }
    parts.push(value);
  }
  return Buffer.concat(parts);
}

/// `{icons}` for the page's `link.favicons {hosts}`: a data URL per host whose site has an icon.
export async function devFavicons(hosts: unknown): Promise<{ icons: Record<string, string> }> {
  const list = Array.isArray(hosts) ? hosts.filter((host): host is string => typeof host === "string") : [];
  const icons: Record<string, string> = {};
  await Promise.all(
    list.slice(0, MAX_HOSTS).map(async (host) => {
      const name = faviconHost(host);
      if (!name) return;
      if (!cache.has(name)) {
        if (cache.size >= MAX_KEPT) cache.delete(cache.keys().next().value!);
        cache.set(
          name,
          fetchIcon(name).catch(() => null),
        );
      }
      const icon = await cache.get(name);
      if (icon) icons[host] = icon;
    }),
  );
  return { icons };
}
