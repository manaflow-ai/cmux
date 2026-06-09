const devboxHosts = new Set(["devbox.new", "www.devbox.new"]);

export function shouldRewriteToDevbox(host: string | null, pathname: string) {
  const normalizedHost = host?.split(":")[0]?.toLowerCase() ?? "";
  if (!devboxHosts.has(normalizedHost)) return false;
  return pathname === "/" || pathname === "/devbox";
}
