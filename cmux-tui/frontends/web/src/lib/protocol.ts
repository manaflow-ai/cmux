export const SUPPORTED_PROTOCOL = 7;

export function supportsProtocol(protocol: number): boolean {
  return protocol === SUPPORTED_PROTOCOL;
}
