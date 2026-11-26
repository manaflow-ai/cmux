- 2026-11-14 (lane/customize-experiments-mark): an "Experiment on · #N" chip floats above the footer row at the
  avatar's edge while an unmerged PR's pages are on (`cmux customize use pr:N`), and draws and lays out nothing
  otherwise. Leo, verbatim: "I want it to like look good and look, you know, like it's a part of the app, like it's
  styled properly, like you guys have scrutinized the placement, the layout and whatever, so that it doesn't look
  jank. And I want people to not accidentally soft lock themselves and like have good recovery options or whatever."
  It uses the sidebar-card veil, caption text and chip radius, and never moves the row. Native on purpose: a PR's
  pages can break Settings itself, so its Turn Off runs `customize library off pr-N` through the bundled CLI. View
  `CustomizeExperimentsMarkView` (CmuxNextPages), placement `SidebarFooterBand.placeExperimentsMark`; gallery
  `ui.customize-experiments.mark`. Regressions:
  `SidebarProfileChipTests.theExperimentsMarkShowsNothingWhenOffAndMovesNothingWhenOn`, `CustomizeExperimentsTests`.
