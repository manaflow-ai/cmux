const OFFICIAL_IOS_NAMESPACES = new Set([
  "com.cmux.app",
  "com.cmuxterm.app",
  "dev.cmux.app.beta",
  "dev.cmux.app.internal",
  "dev.cmux.app.demo",
]);
const DEVELOPMENT_IOS_NAMESPACE_PREFIX = "dev.cmux.ios.";
const DEVELOPMENT_MAC_NAMESPACE_PREFIX = "mac:com.cmuxterm.app.debug";
const NON_DEVELOPMENT_MAC_TAGS = new Set(["default", "nightly", "rc", "staging"]);
const APP_STORE_IOS_NAMESPACE = "com.cmux.app";
const OFFICIAL_STABLE_MAC_NAMESPACE = "mac:com.cmuxterm.app";
const OFFICIAL_NIGHTLY_MAC_NAMESPACE = "mac:com.cmuxterm.app.nightly";
const APP_STORE_MIN_NIGHTLY_BASE = [0, 64, 22] as const;
const APP_STORE_MIN_NIGHTLY_BUILD = BigInt("3359013153901");

type BuildBinding = {
  readonly platform: string;
  readonly deviceUuid: string;
  readonly tag: string;
  readonly clientNamespace: string;
  readonly appVersion?: string | null;
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
  if (caller.clientNamespace === APP_STORE_IOS_NAMESPACE) {
    return canAppStoreIOSUseMac(target);
  }
  const targetHasCompatibleNamespace = target.clientNamespace === "legacy"
    || target.clientNamespace.startsWith("mac:");
  if (!targetHasCompatibleNamespace) return false;

  const callerIsDevelopmentIOS = isDevelopmentIOSNamespace(caller.clientNamespace);
  const targetIsDevelopmentMac = isDevelopmentMacNamespace(target.clientNamespace);

  // A tagged DEV iOS build is the control surface for all tagged DEV Mac
  // builds. The tag still identifies each Mac instance for persistence and
  // ordering, but it is not a compatibility lane boundary. Keep this behind
  // the use-only fallback flag so stale-binding revocation remains exact-tag.
  const targetTag = target.tag.trim().toLowerCase();
  if (callerIsDevelopmentIOS) {
    if (!targetIsDevelopmentMac || NON_DEVELOPMENT_MAC_TAGS.has(targetTag)) {
      return false;
    }
    return legacyDefaultFallback || caller.tag === target.tag;
  }

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

/** App Store iOS has a clean compatibility lane. A Mac must identify itself
 * with an official namespace and report the full marketing/nightly stamp; a
 * missing stamp is an old client and is intentionally invisible. */
export function canAppStoreIOSUseMac(target: BuildBinding): boolean {
  if (target.platform !== "mac") return false;
  const namespace = target.clientNamespace;
  const isNightly = namespace === OFFICIAL_NIGHTLY_MAC_NAMESPACE
    || namespace.startsWith(`${OFFICIAL_NIGHTLY_MAC_NAMESPACE}.`);
  if (namespace === OFFICIAL_STABLE_MAC_NAMESPACE || !isNightly) return false;
  const raw = target.appVersion?.trim() ?? "";
  const marketing = raw.split("+", 1)[0]?.trim() ?? "";
  const match = /^(\d+)\.(\d+)\.(\d+)-nightly\.(\d+)$/.exec(marketing);
  if (!match) return false;
  const base = [Number(match[1]), Number(match[2]), Number(match[3])];
  if (base.some((part) => !Number.isSafeInteger(part) || part < 0)) return false;
  for (let index = 0; index < APP_STORE_MIN_NIGHTLY_BASE.length; index += 1) {
    const difference = (base[index] ?? 0) - (APP_STORE_MIN_NIGHTLY_BASE[index] ?? 0);
    if (difference > 0) return true;
    if (difference < 0) return false;
  }
  try {
    return BigInt(match[4]) >= APP_STORE_MIN_NIGHTLY_BUILD;
  } catch {
    return false;
  }
}

function isDevelopmentMacNamespace(clientNamespace: string): boolean {
  return clientNamespace === DEVELOPMENT_MAC_NAMESPACE_PREFIX
    || clientNamespace.startsWith(`${DEVELOPMENT_MAC_NAMESPACE_PREFIX}.`);
}

function isDevelopmentIOSNamespace(clientNamespace: string): boolean {
  return clientNamespace.startsWith(DEVELOPMENT_IOS_NAMESPACE_PREFIX);
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
