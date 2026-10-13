# Proposed CmuxConversation changes for the iMessage team

cnx-ios uses `Packages/iOS/CmuxConversation` exactly as
`origin/feat-imsg-parity-gui` ships it (c4741ca97f05 when this was written). We do not
patch the package. These are the changes Chief would need from it. They are proposals
only and have not been pushed to any `feat-imsg-*` branch.

## 1. Incoming rows follow the send-time drawer in a one-to-one conversation

- **Need:** in Chief, the user wants every bubble to slide left when the transcript is
  swiped to show send times. Earlier feedback said "only the blue ones moved".
- **Package today:** `TimestampDrawerRows.travel(isOutgoing:inAvatarTranscript:reveal:)`
  moves incoming rows only in a group, where they sit in an avatar column. In a 1:1
  transcript they stay still. The package measured this on a real iPhone, and it is
  what Messages does. The side-by-side runs show the same behavior in the lab host and
  in Chief (`evidence/2026-10-13/imsg/*/06-timestamps-held-sbs.png`).
- **Smallest additive option:** a `ConversationPresentationOptions` flag with a default
  of `false`, so current behavior does not change. `MessageCell` and `TypingCell` pass it
  into `inAvatarTranscript`:

  ```swift
  // ConversationPresentationOptions
  public var incomingRowsFollowTimestampDrawer: Bool   // init default false
  // MessageCell.applyShifts / TypingCell.applyTimestampDrawerOffset
  inAvatarTranscript: model.reservesAvatarColumn || incomingFollowsTimestampDrawer
  // ConversationViewController cellForItemAt (message and typing cells)
  cell.incomingFollowsTimestampDrawer = options.incomingRowsFollowTimestampDrawer
  ```

  cnx-ios carried this patch until 92f8e689e693. It is in the history of
  `feat-cnx-ios-imsg` (`git show f7eb555f24e7 -- Packages/iOS/CmuxConversation`).
- **Until the package has it:** Chief keeps Messages' behavior. Outgoing rows slide and
  incoming rows stay still.

## 2. Replace the service line in New Message

- **Need:** Chief must not show "iMessage" or "Encrypted". `ConversationPresentationOptions`
  already replaces both in a conversation's start header (`serviceTitle`,
  `serviceSubtitle`). New Message (`ConversationComposeViewController`) has no such
  option.
- **Package today:** the line under the To: field shows "iMessage" whenever every
  resolved recipient's service is `.iMessage`. A `ConversationContact`'s service is
  `.iMessage` or `.sms` and is never nil, so a contact always resolves to one of the
  two. Chief's directory now returns plain contacts. Picking Chief or an agent
  therefore shows "iMessage" and the encrypted line in the sheet.
- **Smallest additive option:**
  `public var serviceLine: (title: String, subtitle: String)?` on
  `ConversationComposeViewController`. When it is set, it replaces the iMessage line.
  The SMS line keeps Messages' wording. cnx-ios carried this patch until 92f8e689e693.

## 3. Observations that are the package's own behavior (not Chief's)

These reproduce the same way in the lab host built from `origin/feat-imsg-parity-gui`
and in Chief, on iOS 26.5 and iOS 27.0. We list them so the iMessage team can confirm
they are intended. Chief will not work around them.

- **Rows behind the header.**
  - iOS 26: the header backdrop is a measured color wash, with a peak opacity of 0.60 in
    dark mode (`ConversationTopEdgeGeometry`). Rows stay readable behind the back button,
    avatar and name. That is the "bleed" in the user's screenshot.
  - iOS 27: rows are blurred (UIKit's soft edge effect) instead.
  - Both hosts look identical (`01-open`, `02-under-header`).
- **Tapback badges near the header.** A tapback badge scrolls under the header the same
  way in both hosts (`10-heart-under-header`).
- **Composer input in the lab host (intermittent).** In two runs the lab host's composer
  dropped synthesized typing after Reply or after a tap on the field, while Chief's
  composer, running the same package code, took it every time. We did not find the cause.
  It may be the lab app's window or focus handling, or the harness.

## 4. The cmux iOS app crashes at launch on iOS 26.5 when built with Xcode 27

- **What happens:** a Debug simulator build of `ios/cmux.xcworkspace` (scheme `cmux-ios`) from
  `origin/feat-imsg-parity-gui`, built with Xcode 27.0 (27A266a), is killed by dyld at launch on
  the iOS 26.5 runtime. The log says `Symbol not found: _swift_initBorrow`, referenced from
  `cmux.debug.dylib`. The symbol comes from swift-collections' `InternalCollectionsUtilities`.
  The same build runs on iOS 27.0.
- **Also:** `MobilePinnedNavigationBar.swift` calls `.toolbarMinimizeBehavior(.never, for:
  .navigationBar)`. That API does not exist in the Xcode 27.0 SDK, so the file does not
  compile. We removed that line in our scratch checkout only.
- **How we worked around it:** on iOS 26 the reference was their `ConversationLabView.swift`,
  copied unchanged into a scratch app (see [imsg-parity.md](imsg-parity.md)).

## 5. The trailing header button's VoiceOver label for a custom symbol

- **Need:** Chief passes `trailingSymbol: "clock.arrow.circlepath"` for its history button.
- **Package today:** `ConversationHeaderView` labels the button "FaceTime" for a `video*`
  symbol and "Call" for any other symbol, so VoiceOver reads Chief's history button as "Call".
- **Smallest additive option:**
  `ConversationPresentationOptions.trailingAccessibilityLabel: String?`, with a default of nil
  that keeps the current labels.
