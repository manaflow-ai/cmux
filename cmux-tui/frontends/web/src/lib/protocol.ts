export const SUPPORTED_PROTOCOL = 11;

export function supportsProtocol(protocol: number): boolean {
  return protocol === SUPPORTED_PROTOCOL;
}
