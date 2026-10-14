# Draft: #13742 trust call for the cmux-next iPhone link

Not posted. This is the draft of one consolidated comment for
https://github.com/manaflow-ai/cmux/issues/13742. It covers the four trust
decisions behind cmux on iPhone (the cnx app) reaching a cmux-next Mac. The
relay analysis is `cnx-ios/SECURITY.md`; the pairing and approval design is
`cnx-ios/verify/phone-approvals.md` (both on `feat-cnx-ios`).

---

**Trust call: cmux on iPhone connecting to a cmux-next Mac (#20414, #20491, #20531, `feat-cnx-ios-fileroots`)**

With Settings > Mobile > Allow iPhone Connections on, the cmux app on the same
account's iPhone opens the Mac's workspaces, terminals, browser tabs, agent
chats and Chief. Every phone request reaches the Mac through `cnx-hostd`, a
helper the Mac app runs, which passes it to one service (`daemon`, `acpmux`,
`chief`, `file`, `upload`) through a default-deny policy. Four calls need an
answer before these land.

Threats considered for each: a stolen sign-in token, a malicious or
compromised Mac, a lost phone, an observer on the relay or TURN path, and
prompt injection from agent output.

Things that hold for all four:

- **Admission.** The Worker stamps the dialer's user on every signal
  (`fromUserId`, PROTOCOL.md "Admission"), and hostd admits only the Mac's
  own user. Another account never gets a link.
- **Transport.** Link traffic is WireGuard or DTLS end to end. The Worker, the
  WebRTC relay and Cloudflare TURN see ciphertext, timing, sizes and device
  ids. They can't read or change commands. The Worker does relay the
  transport keys, so a compromised Worker could sit in the middle. Pairing
  (decision 2) narrows that, but its signature isn't bound to the transport
  keys yet; channel binding is a follow-up (`phone-approvals.md`, "Residual
  risks").
- **The phone is not the person on the Mac's daemon.** It can't send
  `client-hello` or `origin.confirmation.issue`, so the daemon gives it origin
  `agent`. Person-only daemon operations refuse it.

### 1. The Mac hosts iPhone links (#20414)

**What changes.** A new setting, `mobile.allowIPhoneConnections`, off by
default, with agent policy `userOnly` (like `computerUse.enabled`): only the
person turns it on, and agent, script and page writes are refused. When it's
on, the app runs `cnx-hostd`.

- `daemon`: the phone types into the person's terminals and opens terminals
  and tabs. Creation commands take only size and placement fields, so
  `argv`, `command`, `cwd` and `env` are refused
  (`refuses_unlisted_and_command_bearing_requests`). There's no `run`,
  `respawn-*` or `eval`.
- Browser tabs: a URL the phone opens must be `http(s)://` or `about:blank`
  (`browser_tabs_open_web_pages_only`).
- `acpmux`: the phone prompts agents as a remote (`Web`) connection. It never
  gets the LocalApp token, and from `Web` an allow is only ever
  `allow_once`.

**Threats and mitigations.**

| Threat | What stops it | What's left |
| --- | --- | --- |
| Stolen sign-in token | Admission is same-user only, so the token must be the person's. With #20491, a token alone reaches no service. | Without #20491, a token is the whole device trust: anyone holding it reaches the terminals. |
| Malicious Mac | The phone dials only Macs on its own account, and sees what that Mac sends. | The phone trusts the Worker's Mac list. Nothing in `phone-approvals.md` pins a Mac key, so a host registered with a stolen token would get what the person types or uploads to it. |
| Lost phone | Remove in Settings > Mobile ends the phone's live links (`drop_phone`). | A phone still signed in registers again. Keeping it out needs signing that session out of the account. |
| Relay observer | End-to-end WireGuard or DTLS. | Metadata. |
| Prompt injection | A link in agent output opens only as a web page in the Mac browser; `file:`, `javascript:` and app schemes are refused. | The `http(s)` narrowing is in the Rust policy only; the Swift mirror (`DaemonLanePolicy.swift`) keeps the same command list. |

**Recommendation: approve the host, and land #20414 only with #20491's
pairing.** The phone is a scoped remote keyboard for the account owner, not
the owner itself, and every command-bearing field is refused.

**Alternative:** land #20414 alone, still off by default. That ships a setting
whose only device check is the sign-in token.

### 2. Pairing and Face ID-signed approvals (#20491)

**What changes.**

- Each phone gets one dialog on the Mac: "Allow “<phone>” to connect to this
  Mac?". The body names the account, the key's fingerprint and when the
  Worker first saw that device (`registered_at_ms`). Only the person can
  answer it; `debug.dialog` can't press it.
- Every link then proves the approved Secure Enclave identity key. Channels
  opened before that wait for it, and fail `unpaired` without it.
- An Allow or a question answer from the phone counts only with a second
  enclave key's signature, made after Face ID or the passcode. It's bound to
  one prompt, option, answer set, Mac and daemon run, expires within
  5 minutes, and counts once (acpmux `hub/approvers.rs`). Deny and decline
  stay unsigned, because they grant nothing.
- acpmux takes the approver list only from the person's connection, and keeps
  it in memory only.

**Threats and mitigations.**

| Threat | What stops it | What's left |
| --- | --- | --- |
| Stolen sign-in token | A token can only ask for pairing. Prompts are limited to one `auth` per link, 3 new keys per device and 6 in all per 10 minutes. A refusal silences that device for 10 minutes. The dialog shows how new the device is. | Prompt fatigue: a person who clicks Allow on a spoofed name pairs the attacker. |
| Malicious Mac | The phone signs only a challenge that names the Mac it dialed. An approval signature binds that Mac and daemon run, so it can't be replayed elsewhere. | The signed payload doesn't bind the text the phone showed. A compromised Mac could show one command and ask for another, but a compromised same-user Mac can already allow its own prompts. |
| Lost phone | Approvals need Face ID every time. Settings > Require Face ID locks the whole app. | The identity key needs no Face ID by design, so an unlocked phone with Require Face ID off can still type into terminals. |
| Relay observer | Signatures are one-time and bound to the prompt. | A compromised Worker could relay a pairing challenge to the real phone and ride its link until channel binding lands. |
| Prompt injection | The Face ID sheet names the tool ("Allow “rm -rf build”"). Agents can't enroll keys. | The person still has to read what they allow. |

A same-user process that writes the app's paired-devices file can add its own
key. That's the same class as an agent editing acpmux's `config.json`
(`phone-approvals.md`, "Residual risks").

**How this compares to D11.** The D11 phone-allow bridge (this issue,
2026-10-10) anchored trust in an App Attest presence key on the Worker. This
design anchors it in the person's approval on the Mac of a Secure Enclave key,
so a session that registers a fake iOS install can't answer: it never holds
an approved key. It doesn't check App Attest.

**Recommendation: approve.** It matches Lawrence's 2026-10-13 rule that every
remote connection is authenticated and pairing needs a human surface, and it
keeps the phone's allows narrower than that rule permits.

**Alternatives:** add App Attest at pairing too, so only a genuine iPhone app
can be approved (more Worker work, no change for the person). Or keep the
phone deny-only and answer every Allow on the Mac.

Live run: all pass on a cmux Mac mini and a simulator (`phone-approvals.md`,
"Verification"). acpmux's `person_allow.rs` hasn't run on the Testbox; #20491's
CI runs it.

### 3. Chief over the link, including engine and avatar (#20531)

**What changes.** A `chief` service splices to the Chief home's own session
socket, filtered both ways by `ChiefPolicy` (`chief_policy.rs`). The phone
reads and writes only conversations whose participants are the owner and
agents. It can send, edit, react, answer Chief's questions and upload
attachments. With the `cmux.protocol/2` operations it can read and change
Chief's harness, model, effort and speed (`chief.engine.get`/`set`), and stop
a turn (`chief.stop`). #20531 adds `avatar` to `chief.engine.set`, and a
`chief-profile-changed` event that carries only that text.

The phone connects to the Chief socket as the Mac owner (`user_local`),
unlike `daemon`, where it's `agent`. So the phone's avatar edit counts as the
person's, like the Mac's own avatar field, which isn't person-only.

**Threats and mitigations.**

| Threat | What stops it | What's left |
| --- | --- | --- |
| Stolen sign-in token | Pairing, as in decision 2. | None beyond decision 2. |
| Malicious Mac | Chief is the Mac's own. | None new. |
| Lost phone | Remove and pairing, as above. | A phone with Require Face ID off can message Chief, which runs agents under its own policy. |
| Relay observer | End to end. | Metadata. |
| Prompt injection | The phone can't bind as an agent or as Chief (`conversation-bind`, `conversation-agent-token` refused). Command-bearing params, `participants.add`, `actor`, and every terminal, workspace and `cloud-*` command are refused. The avatar is at most 16 characters, with no control characters or picture names. | `conversation-op: question.answer` passes with the owner stamped as respondent, without a Face ID signature. Chief has no permission card yet; when it gets one, its Allow goes through the signed path (`phone-approvals.md`, "Known gaps"). |

**Recommendation: approve,** with one condition: before Chief's questions can
grant anything, their answers from the phone go through the signed path. The
avatar is cosmetic, and engine choice only picks among options the brain
validates.

**Alternatives:** allow Chief messages but refuse `chief.engine.set` (engine
and avatar stay Mac-only). Or keep Chief off the link.

### 4. File previews below the folder of a live tab (`feat-cnx-ios-fileroots` at 43f30346)

**What changes.** Files & Links on the phone previews paths a terminal or
agent printed. Today `file` reads only `CNX_FILE_ROOTS`, the chat roots from
Settings, and there are none by default, so every preview fails. Option (a)
adds the folder of any tab the app's daemon lists right now (`list-workspaces`,
the rule `upload` already writes by), read-only:

- never `/`, the home folder or a folder above it (`shareable_tab_folder`), so
  a shell left in `~` shares nothing;
- no hidden names below the tab folder (`.env`, `.git/`, `.ssh/`), except the
  phone's own uploads under `.cmux/` (`hidden_below`);
- symlinks and `..` resolve before the check, and after the open the
  descriptor's real path (`F_GETPATH`) is checked against the same roots;
- each read asks the daemon again, so a closed tab's folder stops at once, and
  a daemon that doesn't answer shares nothing.

Regular files only, at most 64 MiB. It never lists, writes or executes.

Option (b): the app passes every workspace folder as a file root. That shares
folders with no open tab, and keeps sharing a closed one until hostd restarts.

**Threats and mitigations (a).**

| Threat | What stops it | What's left |
| --- | --- | --- |
| Stolen sign-in token | Pairing. | None beyond decision 2. |
| Malicious Mac | Files flow Mac to phone only. | None new. |
| Lost phone | Remove and pairing. | An unlocked phone can read project files in open tab folders. It can already `cat` them in those tabs' terminals. |
| Relay observer | End to end. | Metadata. |
| Prompt injection | An injected path such as `~/.ssh/id_ed25519`, `.env` or a symlink out is refused. The bytes go only to the owner's own phone. | A secret in a non-hidden file inside a project folder (`credentials.json`) is readable. |

**Recommendation: (a).** It gives no authority the same link's `daemon`
service doesn't already give, since the phone has terminals in those folders.
It tracks what the person has open, and it ends when the tab closes. (b) shares
more for longer.

Evidence: unit tests for each refusal
(`files_of_a_live_tab_folder_are_readable_and_nothing_else`,
`hidden_paths_below_a_tab_folder_are_refused`,
`without_a_daemon_no_tab_folder_is_shared`) and the `file` cases in
`tests/host.rs`, per `SECURITY.md` on that branch. No live run on a Mac yet.

### Decisions

- **iPhone host (#20414):** may the Mac app host iPhone links behind the
  person-only `mobile.allowIPhoneConnections`, with the phone as an `agent`
  origin and command-bearing params refused? Reply `approve the iPhone host
  with pairing` (land #20414 only together with #20491) or `approve the
  iPhone host alone` (land #20414 first; the sign-in token is the only device
  check until #20491) or `hold the iPhone host`.
- **Pairing and Face ID approvals (#20491):** may a Mac-approved phone allow
  agent prompts and answer questions with a Face ID-signed, one-time
  signature? Reply `approve pairing and Face ID approvals` or `require App
  Attest at pairing too` or `keep the phone deny-only`.
- **Chief over the link (#20531):** may the paired phone use Chief
  conversations, `chief.engine.get`/`set` and `chief.stop`, with its avatar
  edit counting as the person's? Reply `approve Chief over the link` (Chief
  question answers move to the signed path before they can grant anything)
  or `Chief without engine and avatar edits` or `keep Chief off the link`.
- **File previews (`feat-cnx-ios-fileroots`):** what may `file` read? Reply
  `approve fileroots (a)` (read-only below the folder of a live tab, no
  hidden names, not `/` or `~`) or `share workspace folders (b)` (every
  workspace folder, until hostd restarts) or `keep files blocked` (chat roots
  only, none by default).
