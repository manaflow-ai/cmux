export const DEFAULT_NATIVE_RETURN_TO = "cmux://auth-callback";

const NATIVE_SCHEMES = ["cmux://", "cmux-dev://"] as const;

export function isNativeReturnScheme(value: string | null | undefined): boolean {
  if (!value) return false;
  return NATIVE_SCHEMES.some((scheme) => value.startsWith(scheme));
}

export type NativeHandoffArgs = {
  refreshToken: string | undefined;
  accessToken: string | undefined;
};

export function shouldEmitNativeHandoff(args: NativeHandoffArgs): boolean {
  return Boolean(args.refreshToken && args.accessToken);
}
