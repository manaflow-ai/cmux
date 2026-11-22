// Sites (registrable domains) for the dev driver's cookie scoping. The app asks macOS's Public Suffix List
// (BrowserReplPublicSuffixList in Packages/macOS/CmuxBrowser, CFNetwork's
// lookup); Node has none, so this stand-in holds the suffixes the tests and
// fixtures use and applies the same walk: the longest public suffix wins,
// and a host with none (an IP address, localhost, a public suffix itself, a
// name under an unknown top-level label) is its own site.
import { domainToASCII } from "node:url";

const SUFFIXES = new Set([
  "com", "org", "net", "io", "dev", "app", "uk", "co.uk", "org.uk", "at", "co.at", "or.at",
  "jp", "co.jp", "au", "com.au", "cn", "xn--55qx5d.cn", "ck", "github.io", "gitlab.io",
  "pages.dev", "vercel.app", "netlify.app", "herokuapp.com", "blogspot.com",
]);

const isPublicSuffix = (name) => SUFFIXES.has(name) || (/^[^.]+\.ck$/.test(name) && name !== "www.ck");
const isIP = (host) => host.startsWith("[") || /^(\d+|0x[0-9a-f]+)$/i.test(host.split(".").pop() || "");

export function siteOf(hostname) {
  let host = String(hostname || "").trim().replace(/^\.+/, "").replace(/\.+$/, "").toLowerCase();
  if (host.includes(":") && !host.startsWith("[")) host = `[${host}]`;
  if (!host || isIP(host)) return host;
  host = domainToASCII(host) || host;
  const labels = host.split(".");
  if (labels.length < 2 || labels.some((l) => !l)) return host;
  for (let start = 0; start < labels.length - 1; start++) {
    if (isPublicSuffix(labels.slice(start + 1).join("."))) return labels.slice(start).join(".");
  }
  return host;
}
