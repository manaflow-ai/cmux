export const SUPPORTED_PROTOCOL = 8;

export function supportsProtocol(protocol: number): boolean {
  return protocol === SUPPORTED_PROTOCOL;
}
