const NATIVE_AUTH_CALLBACK_TARGET = "auth-callback";

const NATIVE_SCHEMES = ["cmux://", "cmux-nightly://", "cmux-dev://"] as const;

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
  if (!scheme) return null;

  const callback = new URL(`${scheme}${NATIVE_AUTH_CALLBACK_TARGET}`);
  try {
    const source = new URL(value ?? "");
    const state = source.searchParams.get("state");
    if (state) callback.searchParams.set("state", state);
  } catch {}
  return callback.toString();
}

export type NativeHandoffArgs = {
  refreshToken: string | undefined;
  accessToken: string | undefined;
};

export function shouldEmitNativeHandoff(args: NativeHandoffArgs): boolean {
  return Boolean(args.refreshToken && args.accessToken);
}
