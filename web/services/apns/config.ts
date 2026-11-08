export interface ApnsProviderConfiguration {
  readonly keyP8: string;
  readonly keyId: string;
  readonly teamId: string;
}

export function resolveApnsProviderConfiguration(
  keyP8: string | undefined,
  keyId: string | undefined,
  teamId: string | undefined,
): ApnsProviderConfiguration | null {
  if (!keyP8?.trim() || !keyId?.trim() || !teamId?.trim()) return null;
  return { keyP8, keyId, teamId };
}
