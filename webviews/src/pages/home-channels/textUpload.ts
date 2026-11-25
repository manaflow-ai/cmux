/** The attachment reader only needs these fields. Text already lives in the draft string; keep
 * that string and a sparse byte index instead of making another whole UTF-8 file in memory. */
export type UploadSource = Pick<File, "name" | "type" | "size" | "slice">;

const INDEX_CHARS = 16 * 1024;
/** Inline owner budget, not a send limit: larger text goes through the attachment upload. */
export const INLINE_TEXT_BYTES = 64 * 1024;

export class TextUpload implements UploadSource {
  readonly name = "message.txt";
  readonly type = "text/plain";
  readonly size: number;
  private readonly index: { char: number; byte: number }[] = [];

  constructor(private readonly content: string) {
    const encoder = new TextEncoder();
    let char = 0;
    let byte = 0;
    while (char < content.length) {
      this.index.push({ char, byte });
      let end = Math.min(char + INDEX_CHARS, content.length);
      // Keep a surrogate pair together so encoding slices matches encoding the original string.
      const high = content.charCodeAt(end - 1);
      const low = content.charCodeAt(end);
      if (high >= 0xd800 && high <= 0xdbff && low >= 0xdc00 && low <= 0xdfff) end -= 1;
      byte += encoder.encode(content.slice(char, end)).length;
      char = end;
    }
    this.index.push({ char, byte });
    this.size = byte;
  }

  slice(start = 0, end = this.size, contentType = ""): Blob {
    const offset = (value: number) => Math.max(0, Math.min(value < 0 ? this.size + value : value, this.size));
    const from = offset(start);
    const until = Math.max(from, offset(end));
    let lo = 0;
    let hi = this.index.length - 1;
    while (lo < hi) {
      const mid = Math.ceil((lo + hi) / 2);
      if (this.index[mid]!.byte <= from) lo = mid;
      else hi = mid - 1;
    }
    const parts: Uint8Array<ArrayBuffer>[] = [];
    const encoder = new TextEncoder();
    for (let at = lo; at + 1 < this.index.length && this.index[at]!.byte < until; at += 1) {
      const block = this.index[at]!;
      const next = this.index[at + 1]!;
      const bytes = encoder.encode(this.content.slice(block.char, next.char));
      parts.push(bytes.subarray(Math.max(0, from - block.byte), Math.min(bytes.length, until - block.byte)));
    }
    return new Blob(parts, { type: contentType });
  }
}
