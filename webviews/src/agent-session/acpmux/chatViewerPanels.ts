// One column beside the chat (labs chatViewer, Lucas 2026-10-19): Files and Thread details side by
// side looked wrong. While the viewer (Files or a file) is open beside the chat, Thread details
// floats as the popover it already is beside the browser; closed, it is its own column again.

/// Whether Thread details floats instead of taking its column: the viewer holds the right side.
export function detailsFloat(chatViewer: boolean, open: { diff: boolean; file: boolean; files: boolean }): boolean {
  return chatViewer && (open.file || open.files);
}

/// Opens the viewer, closing Thread details first so it does not come back when the viewer closes.
export function openViewer(details: { shown: boolean; close(): void }, open: () => void): void {
  if (details.shown) details.close();
  open();
}
