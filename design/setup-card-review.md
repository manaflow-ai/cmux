# Review the Set Up cmux card

Issue #46777: "No path: Set Up cmux card cannot be reopened after first run".

Home's Chief settings popover offers **Review Set Up cmux** beside All Chief
Settings. It uses the existing HomeChiefLinkButton appearance and spacing tokens.
The action closes the popover and restores the existing card in Home. Completed
rows keep their state. The link is disabled during a skip-onboarding launch.

An explicitly reopened checklist stays visible until Hide, including when every
row is complete and after relaunch. Review on a visible first-run checklist is
idempotent: it preserves the existing automatic completion behavior.

## Pattern: distinguish first-run completion from explicit review

Restoring visibility alone is insufficient when a subscription automatically
closes completed content. Persist why the card is visible and apply automatic
completion only to first-run mode. Explicit dismissal clears review mode.

Detector: `FirstRunSetupTests.completedCardsOnlyStayVisibleWhenReopened` exercises
the real page subscription for first-run and review modes, relaunch, and Hide.
`HomeChiefSettingsViewTests` checks the accessible link and disabled state.
