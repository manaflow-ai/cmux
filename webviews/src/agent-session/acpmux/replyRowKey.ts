/// The key a reply's row is named by: its stamped segment, with its message id when the segment is
/// of text between turns (`-.<boot>.<n>`). acpmux numbered such text from 1 again after every turn
/// (hub/stream.rs before cmux#48659), so one id named two replies an hour apart: a page holding
/// only the later reply named its row by it, the older page, once read, gave it to the earlier
/// reply, and the chat drew that old reply's text layered over the rows below (cmux#48659). A
/// message id is the same in every page, so the key is too.
export function replyRowKey(segment: string, messageId: string | undefined): string {
  return segment.startsWith("-.") && messageId ? `${segment}~${messageId}` : segment;
}
