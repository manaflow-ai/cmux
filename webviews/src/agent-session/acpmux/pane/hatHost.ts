import { type AcpmuxPermission } from "../model";
import { callNative } from "../callNative";
import { declineReply, isPending, replyParams } from "../question/model";

/// Declines the chat's own waiting question for a reply the person typed instead (the composer's
/// send), then sends the reply; with no question waiting it sends at once. A decline that failed
/// leaves the question waiting, and the reply still goes.
export function withdrawForTypedReply<T>(
  permission: AcpmuxPermission | undefined,
  client:
    | { markAnsweredInChat(permissionId: string): void; unmarkAnsweredInChat(permissionId: string): void }
    | undefined,
  send: () => Promise<T>,
): Promise<T> {
  const question = permission?.question;
  const sent = question && isPending(question) ? declineReply(question) : undefined;
  if (!sent || !permission) return send();
  client?.markAnsweredInChat(permission.permissionId);
  return callNative("chat.permission", replyParams(sent))
    .catch(() => client?.unmarkAnsweredInChat(permission.permissionId))
    .then(send);
}
