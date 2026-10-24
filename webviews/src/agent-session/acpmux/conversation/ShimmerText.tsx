// SPINNERS-OFF-MAIN (Lawrence 2026-10-21: "is it running on main thread? should it be or is it wasteful
// in terms of cpu?"). The running line's shimmer as two layers the compositor moves: the words rest in
// the dim color (`__base`); a band (`__band`, masked to a soft stripe) slides across the line while
// its lit copy of the words (`__lit`) slides back by the same amount, so the lit words stay put under
// the moving stripe. Both loops are `transform` only (conversation.css `cmux-shimmer-band` /
// `cmux-shimmer-lit`, on the shared clock), so the page's main thread paints nothing per frame; the
// old shimmer moved a text-clipped gradient's `background-position`, which repainted the words every
// frame. The lit copy is CSS generated content (`content: attr(data-text)`) inside an aria-hidden
// band: the DOM holds the words once, so the line reads, copies and finds them once.

/// `text` with the shimmer layers (the band shows only while loops run; otherwise the words alone).
export function ShimmerText({ text }: { text: string }) {
  return (
    <>
      <span className="cv-shimmer__base">{text}</span>
      <span className="cv-shimmer__band" aria-hidden="true">
        <span className="cv-shimmer__lit" data-text={text} />
      </span>
    </>
  );
}
