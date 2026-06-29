import type { NextRequest } from "next/server";

export const NATIVE_HANDOFF_COOKIE = "cmux-native-auth-handoff";
export const NATIVE_HANDOFF_PARAM = "cmux_auth_handoff";
export const NATIVE_PLATFORM_PARAM = "cmux_native_platform";

const NATIVE_SCHEME = "cmux://";
const NATIVE_SCHEMES = new Set(["cmux", "cmux-nightly", "cmux-ios", "cmux-ios-beta"]);
const LOCAL_NATIVE_SCHEMES = new Set(["cmux-dev", "cmux-ios-dev"]);
const MOBILE_NATIVE_SCHEMES = new Set(["cmux-ios", "cmux-ios-beta", "cmux-ios-dev"]);
const MOBILE_WEB_SIGN_IN_ERROR = "mobile_web_sign_in_requires_code";

export type NativePlatform = "desktop" | "mobile" | "unknown";

export type AfterSignInMessages = {
  title: string;
  body: string;
  button: string;
  iphoneButton: string;
  testFlightButton: string;
};

export type NativeReturnLink = {
  href: string;
  label: string;
};

export function nativePlatformFromValue(value: string | null): NativePlatform {
  if (value === "desktop" || value === "mobile") return value;
  return "unknown";
}

function isLocalRequest(request: NextRequest): boolean {
  const hostHeader = request.headers.get("host");
  const host = (hostHeader?.split(":")[0] ?? request.nextUrl.hostname).toLowerCase();
  return host === "localhost" || host === "127.0.0.1" || host === "::1";
}

function localAllowedNativeSchemes(): Set<string> {
  const values = [
    process.env.CMUX_AUTH_CALLBACK_SCHEME,
    process.env.CMUX_ALLOWED_NATIVE_CALLBACK_SCHEMES,
    process.env.CMUX_DEV_NATIVE_CALLBACK_SCHEMES,
  ];
  const schemes = new Set<string>();
  for (const value of values) {
    for (const raw of value?.split(/[\s,]+/) ?? []) {
      const scheme = raw.trim().replace(/:\/\/.*$/, "").replace(/:$/, "");
      if (/^cmux-dev-[a-z0-9-]+$/.test(scheme)) schemes.add(scheme);
    }
  }
  return schemes;
}

export function isAllowedNativeReturnTo(href: string, request: NextRequest): boolean {
  try {
    const url = new URL(href);
    if (url.hostname !== "auth-callback") return false;
    if (url.pathname !== "" && url.pathname !== "/") return false;
    const scheme = url.protocol.replace(":", "");
    if (MOBILE_NATIVE_SCHEMES.has(scheme) && !url.searchParams.has("cmux_auth_state")) return false;
    if (NATIVE_SCHEMES.has(scheme)) return true;
    if (LOCAL_NATIVE_SCHEMES.has(scheme)) return isLocalRequest(request);
    return isLocalRequest(request) && localAllowedNativeSchemes().has(scheme);
  } catch {
    return false;
  }
}

export function isMobileNativeReturnTo(href: string): boolean {
  try {
    const scheme = new URL(href).protocol.replace(":", "");
    return MOBILE_NATIVE_SCHEMES.has(scheme);
  } catch {
    return false;
  }
}

export function buildNativeHref(
  baseHref: string | null,
  refreshToken: string | undefined,
  accessCookie: string | undefined
): string | null {
  if (!refreshToken || !accessCookie) return baseHref;
  const href = baseHref ?? `${NATIVE_SCHEME}auth-callback`;
  try {
    const url = new URL(href);
    url.searchParams.set("stack_refresh", refreshToken);
    url.searchParams.set("stack_access", accessCookie);
    return url.toString();
  } catch {
    return `${NATIVE_SCHEME}auth-callback?stack_refresh=${encodeURIComponent(refreshToken)}&stack_access=${encodeURIComponent(accessCookie)}`;
  }
}

export function buildMobileNativeErrorHref(baseHref: string): string | null {
  try {
    const url = new URL(baseHref);
    url.searchParams.delete("stack_refresh");
    url.searchParams.delete("stack_access");
    url.searchParams.set("cmux_auth_error", MOBILE_WEB_SIGN_IN_ERROR);
    return url.toString();
  } catch {
    return null;
  }
}

export function fallbackNativeLinks(
  refreshToken: string,
  accessCookie: string,
  messages: AfterSignInMessages,
  platform: NativePlatform = "unknown"
): NativeReturnLink[] {
  const desktopLinks: NativeReturnLink[] = [
    { href: "cmux://auth-callback", label: messages.button },
  ];
  const links = platform === "mobile" ? [] : desktopLinks;
  return links.flatMap((link) => {
    const href = buildNativeHref(link.href, refreshToken, accessCookie);
    return href ? [{ ...link, href }] : [];
  });
}

export function nativeReturnLabel(href: string, messages: AfterSignInMessages): string {
  try {
    const scheme = new URL(href).protocol.replace(":", "");
    if (scheme === "cmux-ios-beta") return messages.testFlightButton;
    if (scheme === "cmux-ios" || scheme === "cmux-ios-dev") return messages.iphoneButton;
  } catch {}
  return messages.button;
}
