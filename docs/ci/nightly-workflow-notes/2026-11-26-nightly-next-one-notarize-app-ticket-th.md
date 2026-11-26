# nightly-next-one: Notarize app ticket through final DMG

Where: the `nightly-next-one` job in `.github/workflows/nightly.yml`, above `- name: Notarize app ticket through final DMG`.

One Apple round: the DMG's ticket, stapled to the DMG. The app inside carries no ticket of its own
(CMUX_STAPLE_APP_IN_DMG=false); Gatekeeper finds its ticket online, and the verify step below requires
Gatekeeper to call it notarized. Apple gets 40 minutes; a slower build fails this job and the loop's
retry builds again (no hand-off).
