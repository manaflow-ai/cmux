// Attachments in the prompt are ID-bound editor atoms. Paste/drop inserts their pending IDs
// at the caret; resolution fills the same node. Deletion takes the payload out, undo restores it,
// and moving a node preserves its place among text. Settings can draw these same payloads in the
// strip instead, without rewriting the draft or its sent order.
