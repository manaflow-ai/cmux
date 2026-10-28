/** Stable, domain-separated comparison of a guest's real allocation identity. Not an access token. */
export const INSTANCE_IDENTITY_SCHEME = "sha256-v1" as const;
export const instanceFingerprint = async (instance: string): Promise<string> => {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`cmux-vm-instance-v1\n${instance}`));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
};
