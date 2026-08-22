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
  return iosBindingMacLaneCompatible(caller, target, true);
}

/**
 * Forgetting revokes the Mac's binding, so the legacy fallback that pairing
 * gets does not extend here: a namespace-less caller keeps exact tag matching.
 */
export function canIOSBindingForgetMac(
  caller: BuildBinding,
  target: BuildBinding,
): boolean {
  return iosBindingMacLaneCompatible(caller, target, false);
}

function iosBindingMacLaneCompatible(
  caller: BuildBinding,
  target: BuildBinding,
  legacyDefaultFallback: boolean,
): boolean {
  if (caller.platform !== "ios" || target.platform !== "mac") return false;
  const targetHasCompatibleNamespace = target.clientNamespace === "legacy"
    || target.clientNamespace.startsWith("mac:");
  if (!targetHasCompatibleNamespace) return false;

  // iOS builds that predate the X-Cmux-App-Namespace header register as
  // `legacy` and cannot send anything newer, so the missing namespace is the
  // migration signal. The shipped pre-namespace population is the official
  // Beta on the `default` lane; give it the same default->{default,nightly}
  // reach as the official namespaced apps until those builds are sunset.
  const callerHasDefaultLaneReach = caller.tag === "default"
    && (
      OFFICIAL_IOS_NAMESPACES.has(caller.clientNamespace)
      || (legacyDefaultFallback && caller.clientNamespace === "legacy")
    );
  if (callerHasDefaultLaneReach) {
    return target.tag === "default" || target.tag === "nightly";
  }
  return caller.tag === target.tag;
}

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
