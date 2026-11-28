- 2026-11-27 (lane/leo-color-update-card, ask-b6fc7a81c2): Sidebar-Look: Leo, 2026-11-27: "dont put this garish blue
  in man we dont need it to be blue or highlighted" / "overlapping text here what do we doooo". The update cards
  stop taking a chosen accent's hue (D3: the accent colours only links, cursor, focus ring): Restart to Update's
  `.primary` is the selection fill under primary text, the Automatic Updates switch is on in ink, and the download
  bar is the theme's ink. The card's theme tint stays. `SidebarNoticeCardView` reserves the trailing control's
  room beside a text Hide (a ternary bound looser than `+`) and lays Cancel left of Hide instead of on it.
  Gallery `AAUpdateCardInkGalleryTests.renderGallery`; regressions `hideAndCancelNeverOverlap`,
  `aChosenAccentNeverFillsTheCards`.
