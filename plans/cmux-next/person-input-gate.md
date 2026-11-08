# The person-input gate and "Computer use can act as me"

Owner: the agent pane (CmuxNextAgentPane). Rules in Rust: cmux-tui `cmux-agent-pane-policy`
(`src/act_as_me.rs`, `policy.json` `act_as_me_covers`, `gesture_rules`).

## The gate

A frame that grants something (`policy.json` `gesture_rules`: Send, Approve, a mode, a trust grant,
a permission answer, a secret, a login) needs the person's own key press or click in the pane
(`AgentPaneUserGestures`). Who posted an event decides whether it is the person's
(`AgentPanePersonInput.isPerson`): the HID system (source pid 0), or the Apple services a person
drives the Mac through (Screen Sharing, Universal Control, the Accessibility Keyboard). A click or
key another process posts (CGEventPost: a computer-use driver, a script) is not, so a Send an agent
clicks comes back "Not sent: it needs your own key press or click."

Uploads of files the person pasted, dropped or chose (`chat.upload`, the first `chat.upload.begin`
of a batch) need the same gesture, from a credit of their own (`consumeUpload`). One Enter pays for
the send and for the upload of a file pasted just before it, which begins only after the host says
where the paste's files are (Leo, 2026-11-06). Posted input never gives that credit.

## "Computer use can act as me"

Leo, 2026-11-02: "imo you guys ought to be able to do a true send type thing... and also wouldn't
there be cases where you would indeed want auto control or something?"

An explicit, revocable grant on that gate (`AgentPaneActAsMe`), per Mac, **off by default**.

- **What it covers.** While it is on, a key press or click another process posts in an agent pane
  counts as the person's for Send and Retry (`session/prompt`) and Approve
  (`_acpmux/queue_approve`), and nothing wider. A permission or question answer, a mode or config
  option, a folder trust, a harness enable, a secret, a login and a new chat on another machine
  still need the person's own input. A posted gesture is a credit of its own
  (`AgentPaneUserGestures.consumePosted(for:)`): it never stands in for the person's, it is spent
  once, it lasts the normal gesture lifetime, and only input posted while the grant was on counts.
- **Who turns it on.** Only the person's own click on Allow in the app's consent card
  (`AgentPaneActAsMeCard`), read from the click itself by the strict check `PersonInputCheck` (HID
  input only: source pid 0 or the WindowServer, the HID source state), never from the button's
  action. The join consent ask (`JoinConsentCardProvider` on `WebCardPanel`'s native click-only control) takes the same rule. A posted click, a
  key, an Accessibility press and DEBUG automation never turn it on. The card appears once per run
  of the app, when a Send, Retry or Approve that another process's input was behind is refused;
  asking grants nothing. An agent that sees it stops and tells the person, as the computer-use
  consent rule says.
- **What can never turn it on.** No RPC, CLI command, MCP tool, page frame, settings key or config
  file. It is not a cmux.json setting. The person's grant is kept in the app's data-protection
  Keychain (its own access group, which no other process can write); a DEV build without a Team ID
  keeps it for one launch. `defaults write` does nothing: only a forced managed value counts (next).
- **Managed Macs.** An administrator's configuration profile may force `ComputerUseActsAsPerson`
  (boolean) in `com.manaflow.cmux` (docs/mdm). Installing a profile needs an administrator, so it is
  not an agent path. The app reads it with `CFPreferencesAppValueIsForced` in every build (never the
  DEBUG file override) at launch; a profile installed or removed later applies at the next launch.
  This is how test Macs that run published builds end to end get the grant.
- **Turning it off.** One press, with no proof: Turn Off on the pane's indicator or in the card.
  It also holds a managed grant off until the app starts again.
- **Indicator.** While it is on, every agent pane shows a pill at its top right, "Computer use can
  act as you" ("(managed)" for a profile's grant), with Turn Off.
- **Log.** Every let-through is logged (subsystem `com.cmuxterm.app.next`, category
  `agent-pane.act-as-me`, `act_as_me.let_through`) with the method, who holds the grant, and the
  driver: its pid, executable path, bundle id, and cua session when known. The latest 64 are kept in
  memory (`AgentPaneActAsMe.letThroughs`).

Tests: `cmux-tui/crates/cmux-agent-pane-policy/tests/act_as_me.rs` (no agent path grants, off by
default, revocation, coverage), `tests/swift.rs` (the Swift `covers` list is the policy's), and
`CmuxNextAgentPaneTests/AgentPaneActAsMeTests.swift` (the gestures, the relay, the card).
