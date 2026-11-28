- 2026-11-28 (lane/update-card-alignment-try, #65021, carries #60966; commit 8b572dc428f): Lawrence, 2026-11-26, on
  the update cards: "think about alignment and spacing". Leo, 2026-11-27: "we can just try this out in our app rn".
  Hide (Update Ready card) and Cancel/Hide (notice cards) end on the card's padding line, the edge the buttons and bar
  end on, instead of half a padding in; changelog bullets get a hanging indent and sit `space2` under the detail; a
  non-loading detail is as tall as its text (no empty line under a one-line version), loading cards keep two lines;
  the download line pads the percent after itself. The close x stays concentric with the card's corner
  (`Metrics.cornerControl`); Hide/Cancel are text buttons on the first row, not corner controls. Gallery:
  `AAUpdateDownloadCardGalleryTests` (`state-0-available`); regression `UpdateTransferRateTests`.
