export const SUPPORTED_PROTOCOL = 9;

export function supportsProtocol(protocol: number): boolean {
  return protocol === SUPPORTED_PROTOCOL;
}
