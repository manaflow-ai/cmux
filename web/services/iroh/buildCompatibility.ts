const OFFICIAL_IOS_NAMESPACES = new Set([
  "com.cmux.app",
  "com.cmuxterm.app",
  "dev.cmux.app.beta",
  "dev.cmux.app.internal",
  "dev.cmux.app.demo",
]);

type BuildBinding = {
  readonly platform: string;
  readonly deviceUuid: string;
  readonly tag: string;
  readonly clientNamespace: string;
};

export function canIOSBindingUseMac(
  caller: BuildBinding,
  target: BuildBinding,
): boolean {
  if (caller.platform !== "ios" || target.platform !== "mac") return false;
  const targetHasCompatibleNamespace = target.clientNamespace === "legacy"
    || target.clientNamespace.startsWith("mac:");
  if (!targetHasCompatibleNamespace) return false;

  if (
    caller.tag === "default"
    && OFFICIAL_IOS_NAMESPACES.has(caller.clientNamespace)
  ) {
    return target.tag === "default" || target.tag === "nightly";
  }
  return caller.tag === target.tag;
}

export const canIOSBindingForgetMac = canIOSBindingUseMac;

/**
 * Allows one active app bundle to clean up an older binding from the same
 * account, physical device, platform, and exact namespace. Tags and app
 * instances may differ because those are the stale-binding dimensions this
 * operation is intended to retire.
 */
export function canBindingRevokeStale(
  caller: BuildBinding,
  target: BuildBinding,
): boolean {
  return caller.platform === target.platform
    && caller.deviceUuid === target.deviceUuid
    && caller.clientNamespace === target.clientNamespace;
}
