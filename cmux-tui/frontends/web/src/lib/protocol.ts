export const SUPPORTED_PROTOCOL = 10;

export function supportsProtocol(protocol: number): boolean {
  return protocol === SUPPORTED_PROTOCOL;
}
