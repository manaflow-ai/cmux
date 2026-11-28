import { pullRequestOf, type HeaderPullRequest } from "./headerState";
import type { PullRequestActionName } from "./pullRequestActionView";
import type { SendGesture } from "../heldPrompt";

interface Client {
  readonly selectedSession?: string;
  readonly selectionToken: number;
  bindSendGesture(): SendGesture | undefined;
  pullRequestAction(params: { url: string; headSha?: string; action: string }): Promise<unknown>;
}
interface Send {
  text: string;
  expectedSessionId: string;
  gesture?: SendGesture;
  accepted(): void;
}

// Same-chat transport adapter only: Rust supplies authoritative state and prompt context.
export async function pullRequestActionPrompt(
  client: Client,
  sessionId: string,
  pr: HeaderPullRequest,
  action: PullRequestActionName,
  signal: AbortSignal,
  io: { currentClient(): Client | undefined; send(params: Send): Promise<unknown>; error(): Error },
): Promise<HeaderPullRequest> {
  const generation = client.selectionToken;
  const current = () =>
    !signal.aborted &&
    io.currentClient() === client &&
    client.selectedSession === sessionId &&
    client.selectionToken === generation;
  if (!current()) throw io.error();
  // Reserve the click before reading context. The existing single-use prompt ticket keeps
  // its exact chat/prompt binding and lifetime; no new authorization is manufactured later.
  const sends = action === "fixChecks" || action === "addressComments";
  const gesture = sends ? client.bindSendGesture() : undefined;
  const value = await client.pullRequestAction({ url: pr.url, headSha: pr.headSha, action });
  if (!current() || !value || typeof value !== "object") throw io.error();
  const reply = value as Record<string, unknown>;
  const header = pullRequestOf(reply.header);
  if (
    reply.sessionId !== sessionId ||
    !header?.headSha ||
    header.url !== pr.url ||
    (sends && header.headSha !== pr.headSha)
  )
    throw io.error();
  if (sends) {
    if (typeof reply.prompt !== "string" || !reply.prompt.trim()) throw io.error();
    const text = reply.prompt;
    await new Promise<void>((resolve, reject) => {
      io.send({ text, gesture, expectedSessionId: sessionId, accepted: resolve }).then(() => resolve(), reject);
    });
  }
  return header;
}
