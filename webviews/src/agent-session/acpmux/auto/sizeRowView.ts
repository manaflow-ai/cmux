// RFD 0144 piece 9: the read-only Size row's view, as the Rust core answers it
// (cmux-cloud-start-core `size_row`, FFI op `cloud_size_row`). The core decides whether More room is
// offered and what it would raise to; this file only names the shape. Absent while the
// `cloud.moreRoom` setting is off, and the old Auto / Pin row is drawn then.

export type SizeShape = { vcpu: number; memory_gib: number };
export type MoreRoom = "hidden" | "offered" | "on";

/// Mirrors `size_row::View` (serde snake_case).
export type SizeRowView = {
  now?: SizeShape;
  pinned?: SizeShape;
  more_room: MoreRoom;
  /// For the caller that sends the request; the copy never names it.
  raises_to?: SizeShape;
};
