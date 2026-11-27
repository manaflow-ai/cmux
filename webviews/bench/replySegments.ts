// The bench's stand-in acpmux stamps reply segments as acpmux does (settled-page.bench.ts).

/// A session log record as the stand-in keeps it.
export type SegmentedEvent = { kind?: unknown; dir?: unknown; msg?: unknown };

/// As acpmux stamps a reply chunk's record with its reply segment (`_meta.acpmux.segment`, cmux-tui hub/stream.rs
/// `reply_segment_for`): one id for every chunk of one run of reply text, a new one after a turn starts or a tool call
/// cuts it. The pane names a reply's row by it, so a reply longer than a page keeps its row when the older page with
/// its first chunks comes in. Unstamped (a log from before acpmux stamped them) the row was named by the first chunk
/// read, so each older page renamed the reply mid-switch: from round 7 of chat_switch.stream (the running reply past
/// the 400-record page) a frame showed its start as a row of its own over the rest, then one row 47 px shorter, read
/// as a shift no acpmux the pane talks to makes.
export const segmenter = () => {
  let turn = 0;
  let count = 0;
  let open: string | undefined;
  return (event: SegmentedEvent) => {
    const msg = event.msg as { params?: { update?: { sessionUpdate?: string }; _meta?: Record<string, unknown> } };
    if (event.dir === "mux" && event.kind === "user_message") {
      turn += 1;
      count = 0;
      open = undefined;
      return;
    }
    const update = event.dir === "in" ? msg?.params?.update?.sessionUpdate : undefined;
    if (!update) return;
    if (update !== "agent_message_chunk") {
      if (update !== "usage_update" && update !== "available_commands_update") open = undefined;
      return;
    }
    open ??= `t${turn}.bench.${(count += 1)}`;
    msg.params!._meta = { ...msg.params!._meta, acpmux: { segment: open } };
  };
};
