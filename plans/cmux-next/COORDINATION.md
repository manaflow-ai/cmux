See plans/cmux-next/coordination/INDEX.md for the generated coordination ledger.

- cx-czd: `webviews/src/ui/variant-pick/` owns the shared picker/model and PickSink
  contract. Gallery entries opt in with `pick: { beadId, recommendedId }`.
  `conversation/RenderVariantsPick.tsx` is the cx-ncc.38 adapter for Leo's
  `f678062221e` RenderGroup, with preview/expand behavior left to that lane.
  Leo owns the feed implementation; the supplied feed sink is deliberately a no-op.
  HQ branch `feat-gallery-pick` contains the loopback comment endpoint and uninstalled
  LaunchAgent template. No picks edit decisions.md; installation remains with the lead.
