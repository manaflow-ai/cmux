const ASSET_BASE = "https://files.cmux.com/server/";
const TARGET = /^(?:x86_64|aarch64)-(?:linux|darwin|windows)$/u;
const DIGEST = /^[a-f0-9]{64}$/u;
const ROOT_ASSETS = new Set([
  "install.sh", "install.sh.sig", "install.ps1", "install.ps1.sig",
  "bootstrap.json", "bootstrap.json.sig", "SHA256SUMS", "SHA256SUMS.sig",
]);

function isChannelArtifact(parts: readonly string[]): boolean {
  const [, channel, target, name, version] = parts;
  if ((channel !== "stable" && channel !== "beta") || !TARGET.test(target ?? "")) {
    return false;
  }
  if (parts.length === 4) {
    return name === "latest.json" || name === "latest.json.sig";
  }
  // Keep the version alphabet accepted by cmux-server's manifest_url.
  return parts.length === 5 && name === "v" &&
    /^[A-Za-z0-9._+-]+\.json(?:\.sig)?$/u.test(version ?? "");
}

function isBootstrapArtifact(parts: readonly string[]): boolean {
  if (parts.length !== 3 || !DIGEST.test(parts[1] ?? "")) return false;
  const name = parts[2];
  const match = /^(x86_64|aarch64)-(linux|darwin|windows)\.(tar\.gz|zip)$/u.exec(name ?? "");
  if (!match) return false;
  return match[3] === (match[2] === "windows" ? "zip" : "tar.gz");
}

/** Public distribution paths only; no bucket listing, caller URL or credentials. */
export function serverDownloadUrl(parts: readonly string[]): string | null {
  let valid = false;
  switch (parts[0]) {
    case "channel": valid = isChannelArtifact(parts); break;
    case "bootstrap": valid = isBootstrapArtifact(parts); break;
    case "packages":
      valid = parts.length === 2 && /^[a-f0-9]{64}\.tar\.gz$/u.test(parts[1] ?? "");
      break;
    default: valid = parts.length === 1 && ROOT_ASSETS.has(parts[0] ?? "");
  }
  return valid ? ASSET_BASE + parts.map(encodeURIComponent).join("/") : null;
}
