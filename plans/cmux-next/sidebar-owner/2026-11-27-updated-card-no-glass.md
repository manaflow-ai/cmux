- 2026-11-27 (lane/sidebar-update-card-glass): the "Updated to Nightly" card beside the sidebar sits directly on
  the sidebar like the other cards; the native frost behind it (`SidebarUpdatedCardHost.glass`) draws only for the
  in-card preview (`UpdatedCardPreviewMode.above`), where it stands over the rows. Leo, verbatim: "this thing is just
  too weird there's a glass back that shouldnt be there". A sidebar width change snaps the card's room to its new
  wrap instead of springing it, so a resize drag never stretches or jumps the card. Regression:
  `UpdatedCardHoverPreviewTests.theCardBesideTheSidebarHasNoFrostBehindIt`.
