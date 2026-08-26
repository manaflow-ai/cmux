export const SUPPORTED_PROTOCOL = 12;

export function supportsProtocol(protocol: number): boolean {
  return protocol === SUPPORTED_PROTOCOL;
}
