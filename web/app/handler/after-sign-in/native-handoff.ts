const DEFAULT_NATIVE_SCHEME = "cmux://";
const NATIVE_AUTH_CALLBACK_TARGET = "auth-callback";
export const DEFAULT_NATIVE_RETURN_TO = `${DEFAULT_NATIVE_SCHEME}${NATIVE_AUTH_CALLBACK_TARGET}`;

const NATIVE_SCHEMES = [
  DEFAULT_NATIVE_SCHEME,
  "cmux-nightly://",
  "cmux-dev://",
] as const;

export function isNativeReturnScheme(
  value: string | null | undefined,
): value is string {
  if (!value) return false;
  return NATIVE_SCHEMES.some((scheme) => value.startsWith(scheme));
}

export function nativeAuthCallbackForReturnTo(
  value: string | null | undefined,
): string | null {
  const scheme = NATIVE_SCHEMES.find((candidate) =>
    value?.startsWith(candidate),
  );
  return scheme ? `${scheme}${NATIVE_AUTH_CALLBACK_TARGET}` : null;
}

export type NativeHandoffArgs = {
  refreshToken: string | undefined;
  accessToken: string | undefined;
};

export function shouldEmitNativeHandoff(args: NativeHandoffArgs): boolean {
  return Boolean(args.refreshToken && args.accessToken);
}
