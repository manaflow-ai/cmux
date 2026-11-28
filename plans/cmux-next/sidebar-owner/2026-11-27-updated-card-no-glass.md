- 2026-11-27 (lane/sidebar-update-card-glass): Leo, verbatim: "this thing is just too weird there's a glass back that
  shouldnt be there". #60682 hides the native frost behind the resting "Updated to Nightly" card
  (`SidebarUpdatedCardHost.glass` shows only over rows: an open preview, a held or settling card). On top of that, a
  sidebar width change snaps the card's room to its new wrap instead of springing it, so a resize drag never stretches
  or jumps the card. Regression: `UpdatedCardHoverPreviewTests.theCardBesideTheSidebarHasNoFrostBehindIt`.
