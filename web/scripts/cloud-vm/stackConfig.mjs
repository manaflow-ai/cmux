/** Build StackServerApp options while keeping the publishable key optional. */
/** @param {{ projectId: string, publishableClientKey?: string, secretServerKey: string }} options */
export function stackServerAppOptions({ projectId, publishableClientKey, secretServerKey }) {
  return {
    projectId,
    ...(publishableClientKey ? { publishableClientKey } : {}),
    secretServerKey,
  };
}
