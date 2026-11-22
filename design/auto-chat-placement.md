# Auto chat placement

Leo, 2026-11-18: "an auto mode as an umbrella over remote/local/cloud itself. so it just goes.
thats essentialyl what we're doing rn with teh lanes going to various machines".

**Auto** is a place for a new chat, listed above This Mac, joined machines and Cloud. It is the
default for new chats (`agentPane.newChatsIn: "auto"`); a person who turns it off gets the old
default (This Mac). Auto picks where the chat starts and, while the chat runs, moves it when its
inputs change and brings it back when they change back.

## One decision, in Rust

`acpmux/src/chat_place.rs` decides. It reuses `placement.rs` (the Rust port of lane-place's
scoring: room in lanes from RAM, CPU, disk and live agents, `placement_preference` tiers, rank,
holds) to weigh this Mac and each joined machine, and adds what a chat needs that a lane does not:

| Input | Where it comes from |
|---|---|
| Where the folder lives, its size | the chat's `cwd`, measured with a bounded walk (`folderBytes`) |
| Each machine's load, free RAM, disk, live agents | the host health readings `placement.rs` already weighs |
| Battery, on AC, lid closed | host health `power: {batteryPercent, onAc, lidClosed}` (macOS) |
| Network dropping | host health `network: {up}` (`cmux-netwatch`) |
| What the work needs | `needs: {macos, gpu, longBuild}` (the app passes it; a folder with an `.xcodeproj` or `Package.swift` with Apple-only targets implies `macos`) |
| Cloud cost and availability | `cloud: {available, minutesPerHour, gpu}` (the app passes it from the signed-in plan) |

`decide(&Input) -> Verdict`; the verdict is `{place: "local"|"peer"|"cloud", peer, why, reasons,
hosts}`, and is what `_acpmux/place_chat` returns.

The rules, in order:

1. **Needs.** `macos` keeps only macOS machines (Cloud is Linux). `gpu` keeps machines whose
   health says `gpu` and Cloud only when the plan offers one.
2. **The network is down.** The chat stays on this Mac: nothing else can be reached.
3. **The lid is closed, or the Mac is going to sleep.** This Mac is not a candidate.
4. **Battery.** On battery under 20 %, this Mac counts as over load.
5. **This Mac has room** (placement verdict not over its budget, room ≥ 1 lane, and for a long
   build room ≥ 2) → **local**. A small local repo stays local.
6. **Otherwise** the best joined machine with room (placement's order), if any. A folder bigger
   than `copyBudgetBytes` (default 2 GB) prefers a machine that already has it.
7. **Otherwise Cloud**, when available and the work does not need macOS.
8. **Otherwise local** anyway, and the verdict says so (`overloaded`), as lane-place does: load
   only warns.

## Moving a running chat

`rejudge(&Running, &Input) -> Option<Move>` runs on every health change for chats placed by Auto
(not pinned). It moves away on a hard trigger at once (lid closed, sleep), and on load or battery
only after it held for `holdSecs` (120 s). It brings a chat back to where it started when the
trigger has cleared (lid open, on AC or battery ≥ 30 %, this Mac has room for 2 lanes) and the
chat's turn has ended. A chat the person moved or pinned is never moved by Auto.

**Off by default.** Nothing moves a chat on its own unless the person sets
`agentPane.autoPlacement.moveChats` to `true` in `cmux-next.json`. The daemon reads it at each
pass; with it missing or false the rejudge task asks for no move, and `place_chat_event` answers
with nothing moving.

With it on, the daemon's rejudge task (`server/place_auto.rs`) weighs every live chat tagged
`placement=auto` on each sleep word, each peer link change and every 30 s. It runs on macOS only:
Auto weighs "This Mac", and a daemon on a Linux machine a chat was moved to must not rejudge that
chat as if it started there.

Moves reuse Move to Cloud / Bring Back (`cmux link seed push`, `link agent move --sync pull`) and
the peer move (`acpmux session move --host`). For Cloud the daemon emits `chatPlace/move
{session, to, peer, why, back, folderTravel}` to this machine's own clients
(`hub/chat_place_bus.rs`); the app's thin mover runs the existing action for it. A move to or
from a joined machine the daemon runs itself. On sleep the app delays sleep (up to the system's
30 s) while the hand-off finishes (`_acpmux/place_chat_settled`).

`folderTravel` is `project` when the app's pane said folders go by projection (`cmux link project
moves on`): Move to Cloud's seed push projects the folder instead of copying it, and Bring Back
takes the chat's edits from its own upper layer (`cmux link project back`, cmux#45832). Otherwise
it is `copy`: the seed and its three-way pull.

## Copy-on-write over the projection

Each chat moved off this Mac runs on its own copy-on-write layer over the projection of the
person's folder: reads come from the projection, writes go to the chat's layer, and nothing
touches the person's files until the chat comes back, when Bring Back applies the layer.

That layer is projected folders (cmux#45782, cmuxterm-hq RFD 0007): a FUSE mount of the Mac's
folder on the machine, with writes copied up into `upper/` and deletes kept as whiteouts, per
projection name. Auto gives each chat its own projection name, so two chats on one folder get
separate layers. Bring Back over that layer (a three-way pull of `upper/` and the whiteouts) is
cmux#45832; the app's Bring Back takes it for a projected folder, so Auto's return trip needs no
code of its own. Until it lands, a moved chat's folder comes back by today's seed pull.

## Pinning

The chat row shows where the chat runs ("Auto · huge-blue"). One click pins it there: Auto stops
moving it, and the row shows the pin.

## Trying it

`acpmux machine chat-pick [--cwd DIR] [--needs macos,gpu,build] [--cloud] [--running JSON]
[--json]` prints where a new chat on Auto would start and why, and with `--running` the move
Auto would make. It changes nothing.
