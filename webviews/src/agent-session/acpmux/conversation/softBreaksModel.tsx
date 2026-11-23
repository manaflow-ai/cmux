import { type ReactNode } from "react";

/// A run with no space at least this long gets break points; shorter ones fit on any line.
const LONG_TOKEN = 24;
/// Where a long token may end a line: after a range's `..`, a path's `/`, or one of `-_.:=&?#@,`.
const BREAK_AFTER = /\.\.\.?|[/\\\-_.:=&?#@,]/g;
const SPACE = /(\s+)/;

/// `text` with `<wbr>` after each break point of its long tokens; the same string when it has none.
export function softBreaks(text: string, key: string): ReactNode[] {
  if (text.length < LONG_TOKEN) return [text];
  const out: ReactNode[] = [];
  let plain = "";
  let index = 0;
  for (const word of text.split(SPACE)) {
    if (word.length < LONG_TOKEN || SPACE.test(word)) {
      plain += word;
      continue;
    }
    let at = 0;
    for (const m of word.matchAll(BREAK_AFTER)) {
      const end = m.index! + m[0].length;
      if (end >= word.length) break;
      plain += word.slice(at, end);
      out.push(plain, <wbr key={`${key}-wbr${index++}`} />);
      plain = "";
      at = end;
    }
    plain += word.slice(at);
  }
  if (!out.length) return [text];
  if (plain) out.push(plain);
  return out;
}

/// `nodes` with each string's long tokens given break points (softBreaks).
export function softBreakNodes(nodes: ReactNode[], key: string): ReactNode[] {
  return nodes.flatMap((node, index) => (typeof node === "string" ? softBreaks(node, `${key}-${index}`) : [node]));
}
