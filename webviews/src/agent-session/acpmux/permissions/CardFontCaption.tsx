// Gallery-only: the caption under a card drawn in one of the chat's Interface Fonts (cardFontGallery.tsx).
/// The caption under the card, once measured.
export const CardFontCaption = ({ caption }: { caption?: string }) =>
  caption ? (
    <p className="acpmux-muted" data-gallery-card-heights>
      {caption}
    </p>
  ) : null;
