export function isPrivateSharePath(pathname: string): boolean {
  return pathname === "/share" || pathname.startsWith("/share/");
}

export function isPrivateShareURL(value: unknown): boolean {
  if (typeof value !== "string") return false;
  try {
    return isPrivateSharePath(new URL(value, "https://cmux.com").pathname);
  } catch {
    return false;
  }
}
