/** Build StackServerApp options while keeping the publishable key optional. */
export function stackServerAppOptions({ projectId, publishableClientKey, secretServerKey }) {
  return {
    projectId,
    ...(publishableClientKey ? { publishableClientKey } : {}),
    secretServerKey,
  };
}
