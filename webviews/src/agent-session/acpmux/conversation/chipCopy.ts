// A cmux link drawn as its chip (chips/CmuxLinkChip.tsx: a workspace's or chat's title) is text the
// page shows, not the text that was written: every path that turns a selection into text turns a
// chip into its link, as the plain link read before the chips (review of #38166). One module, so
// each serializer composes with it instead of rejecting the others: a reply's copy
// (selectionCopy.ts), math's (mathCopy.ts), the page's own copy of code and tables (``chipText``),
// and the selection a quote or the message menu reads (selectionReplyModel.ts, messageMenu.ts).

/// A cmux link's chip, whose words are a title. A Markdown link's chip (`data-cmux-link-label`) shows
/// the author's own words and copies as them, as its plain anchor did.
export const LINK_CHIP = "a[data-cmux-link]:not([data-cmux-link-label])";

function elementOf(node: Node): Element | null {
  return node.nodeType === Node.ELEMENT_NODE ? (node as Element) : node.parentElement;
}

/// Each chip in `root` (a clone of a selection) as its link's text.
export function chipsAsLinks(root: ParentNode) {
  for (const chip of root.querySelectorAll(LINK_CHIP)) chip.replaceWith(chip.getAttribute("href") ?? "");
}

/// `range` reaching to the whole of a chip either end is inside (a selection of part of a chip's
/// title: its clone leaves out the anchor, so its link would be lost). The same range when neither
/// end is in a chip, so every other selection reads as it did.
export function withWholeChips(range: Range): Range {
  const startChip = elementOf(range.startContainer)?.closest(LINK_CHIP);
  const endChip = elementOf(range.endContainer)?.closest(LINK_CHIP);
  if (!startChip && !endChip) return range;
  const whole = range.cloneRange();
  if (startChip) whole.setStartBefore(startChip);
  if (endChip) whole.setEndAfter(endChip);
  return whole;
}

let last: { key: string; startContainer: Node; endContainer: Node; text: string | null } | undefined;

/**
 * The page's own text of `selected` with each chip as its link; null when it holds no chip (the
 * caller's text is the page's). The text around the chips is what a selection of it reads
 * (`Selection.toString`, from the live layout: a prompt's kept line ends and spaces, a code block's
 * indentation, a table's cells), and a highlighted code block, drawn in a shadow root a light
 * selection does not read, is read by a selection inside it. The person's selection is put back;
 * the answer for the same range and text is kept, so a `selectionchange` listener that reads it
 * again never sets the selection again.
 */
export function chipText(selected: Range): string | null {
  const range = withWholeChips(selected);
  const scope = elementOf(range.commonAncestorContainer);
  const owner = scope?.ownerDocument ?? document;
  const inScope = (element: Element) => range.intersectsNode(element);
  const around = scope?.closest(LINK_CHIP);
  const chips = around ? [around] : [...(scope?.querySelectorAll(LINK_CHIP) ?? [])].filter(inScope);
  if (!chips.length) return null;
  const key = `${range.startOffset}:${range.endOffset}:${range.toString()}`;
  if (
    last &&
    last.key === key &&
    last.startContainer === range.startContainer &&
    last.endContainer === range.endContainer
  )
    return last.text;
  // Where the text is not the page's selection text: each chip, and each shadow root's host.
  const breaks = [
    ...chips,
    ...[...(scope?.querySelectorAll("*") ?? [])].filter((element) => element.shadowRoot && inScope(element)),
  ].sort((a, b) => (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1));
  const selection = owner.getSelection();
  // The person's selection as they made it: its anchor and focus, so a backward one stays backward
  // (a Reply placed at its focus, Shift-arrow growing the same end).
  const kept =
    selection && selection.rangeCount > 0 && selection.anchorNode && selection.focusNode
      ? ([selection.anchorNode, selection.anchorOffset, selection.focusNode, selection.focusOffset] as const)
      : null;
  const read = (start: Node, startOffset: number, end: Node, endOffset: number) => {
    if (!selection) return "";
    selection.setBaseAndExtent(start, startOffset, end, endOffset);
    // Not isCollapsed: WebKit calls a selection inside a shadow root collapsed (seen from the
    // document) while its toString reads its lines. A collapsed one reads "".
    return selection.toString();
  };
  let text = "";
  try {
    let from: [Node, number] = [range.startContainer, range.startOffset];
    for (const element of breaks) {
      const parent = element.parentNode!;
      const index = Array.prototype.indexOf.call(parent.childNodes, element) as number;
      text += read(from[0], from[1], parent, index);
      if (element.matches(LINK_CHIP)) text += element.getAttribute("href") ?? "";
      else {
        // A block of code: its lines on their own, as the page's copy puts them.
        // From its first drawn element to its last: WebKit reads nothing of a selection set on the
        // shadow root itself.
        const drawn = [...element.shadowRoot!.children].filter((child) => !/^(STYLE|SCRIPT|LINK)$/.test(child.tagName));
        const first = drawn[0];
        const end = drawn[drawn.length - 1];
        const code = first && end ? read(first, 0, end, end.childNodes.length).replace(/\n+$/, "") : "";
        if (code) {
          if (text && !text.endsWith("\n")) text += "\n";
          text += `${code}\n`;
        }
      }
      from = [parent, index + 1];
    }
    const tail = read(from[0], from[1], range.endContainer, range.endOffset);
    text += text.endsWith("\n") ? tail.replace(/^\n/, "") : tail;
  } finally {
    if (selection) {
      if (kept) selection.setBaseAndExtent(...kept);
      else selection.removeAllRanges();
    }
  }
  last = { key, startContainer: range.startContainer, endContainer: range.endContainer, text };
  return text;
}

/// The text of a person's selection with each chip as its link: the page's own when it holds none.
export function selectionText(selection: Selection): string {
  if (selection.rangeCount === 0) return selection.toString();
  return chipText(selection.getRangeAt(0)) ?? selection.toString();
}
