// What Markdown reads off a reply's whole text (its footnote order and the folders its paths are
// in), for a streaming reply at the cost of its tail. The reveal draws a reply again on every
// display frame, and reading the whole text each time made a frame's cost grow with the reply:
// at 20,000 words the folder scan alone ran its path pattern over 120 KB a frame. The closed
// blocks' text (incrementalMarkdown.ts) never changes again, so each piece of it is read once, as
// it closes; only the text after it is read on each frame. The results equal a scan of the whole
// text (replyScan.test.ts): no folder pattern matches across the blank line a piece ends at, and a
// piece adds its footnotes only once its fences and code spans close inside it (`footnotePiece`).
import { MAX_REPLY_FOLDERS, replyFolders } from "../chips/replyFolders";
import { footnoteOrder, footnotePiece } from "./markdownModel";

export type ReplyScanResult = { noteIds: string; folderKey: string };

export class ReplyScan {
  private generation = -1;
  /// The folders of the text before `foldersEnd`, in reading order.
  private folders: string[] = [];
  private foldersEnd = 0;
  /// The footnote ids of the sealed text before `notesEnd`; `notesTried`, the closed end a piece
  /// that was not sealed was last read to (so a frame with no new closed text does not read it again).
  private notes: string[] = [];
  private notesEnd = 0;
  private notesTried = 0;
  /// The characters the last read scanned (tests, perf).
  lastReadLength = 0;

  // perf-hot: 1ms/frame agent-chat-stream-reveal
  /// The reply's footnote ids (space-joined) and folders (newline-joined), as Markdown keys them.
  /// `closed` is where the parser's closed text ends and the generation it belongs to.
  read(source: string, closed: { end: number; generation: number }): ReplyScanResult {
    if (closed.generation !== this.generation || closed.end < this.foldersEnd || closed.end < this.notesEnd) {
      this.generation = closed.generation;
      this.folders = [];
      this.foldersEnd = 0;
      this.notes = [];
      this.notesEnd = 0;
      this.notesTried = 0;
    }
    const end = Math.min(closed.end, source.length);
    this.lastReadLength = 0;
    if (end > this.foldersEnd) {
      if (this.folders.length < MAX_REPLY_FOLDERS) {
        this.lastReadLength += end - this.foldersEnd;
        this.folders = merge(this.folders, replyFolders(source.slice(this.foldersEnd, end)), MAX_REPLY_FOLDERS);
      }
      this.foldersEnd = end;
    }
    if (end > this.notesTried) {
      this.notesTried = end;
      this.lastReadLength += end - this.notesEnd;
      const piece = footnotePiece(source.slice(this.notesEnd, end));
      if (piece.sealed) {
        this.notes = merge(this.notes, piece.ids);
        this.notesEnd = end;
      }
    }
    const folders =
      this.folders.length < MAX_REPLY_FOLDERS
        ? merge(this.folders, replyFolders(source.slice(this.foldersEnd)), MAX_REPLY_FOLDERS)
        : this.folders;
    if (this.folders.length < MAX_REPLY_FOLDERS) this.lastReadLength += source.length - this.foldersEnd;
    this.lastReadLength += source.length - this.notesEnd;
    const notes = merge(this.notes, footnoteOrder(source.slice(this.notesEnd)));
    return { noteIds: notes.join(" "), folderKey: folders.join("\n") };
  }
}

/// `head` followed by the entries of `more` it lacks, at most `cap` in all.
function merge(head: string[], more: readonly string[], cap = Infinity): string[] {
  if (!more.length) return head;
  const out = [...head];
  for (const entry of more) {
    if (out.length >= cap) break;
    if (!out.includes(entry)) out.push(entry);
  }
  return out;
}
