/** The web contract for Cloud's durable ForkRuns action. */
export type CloudForkRunsRequest = {
  sourceMachine: string;
  session: string;
  harness: string;
  checkpoint: number;
  parentLabel: string;
};

export type CloudForkRunsChild = {
  childSessionId: string;
  parentLabel: string;
  /** The child transcript as restored by the mocked/native platform adapter. */
  rows?: readonly unknown[];
};

export type CloudForkRuns = (request: CloudForkRunsRequest) => Promise<CloudForkRunsChild>;

/**
 * Runs one durable child fork. The parent is passed as immutable input and is never selected,
 * rewritten or used as the destination; the platform adapter owns the machine snapshot and child
 * opening. Keeping this as a dependency-injected function makes the checkpoint contract testable
 * without a Cloud account.
 */
export async function tryAnotherApproach(
  request: CloudForkRunsRequest,
  forkRuns: CloudForkRuns,
): Promise<CloudForkRunsChild> {
  if (!Number.isInteger(request.checkpoint) || request.checkpoint < 0) throw new Error("invalid checkpoint");
  return forkRuns({ ...request });
}
