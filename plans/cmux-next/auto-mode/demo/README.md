# Auto mode demo

A chat with Claude Code that keeps running in the Cloud when the laptop goes away, and comes
home when the laptop is back. It is a small, independent build of the ideas in
[../DESIGN.md](../DESIGN.md), made to try the whole loop with real machines before the ideas go
into the product. Python 3 standard library only (3.9 or newer); the agent is the `claude` on
each machine's PATH.

```
laptop                         store (one process, on the Cloud machine)          Cloud machine
auto chat  ── lease, events ─▶ who holds each chat, its events, its copy, ◀─ asks for work ── auto cloud
           ◀─ handback ──────  its inbox                                   ── events, copy ─▶
phone      ── auto send ─────▶ inbox
```

## The ideas it keeps

- **One holder per chat.** `device:<name>`, `vm:<name>` or nobody (parked). Every change of
  holder adds one to the chat's **epoch**, and every write names its holder and epoch, so a
  machine that lost the chat cannot write to it.
- **A lease.** The laptop renews it. When it runs out and the chat has work to do, the store
  gives the chat to the Cloud machine. With nothing to do the chat is parked, and a message
  from any device starts it in the Cloud.
- **A copy the Cloud can start from.** The chat's events, Claude Code's session file and the
  folder (content-addressed files; only what changed is sent), stored every few seconds while a
  turn runs and at each turn's end.
- **The chat's event log is its queue.** A `user` event with no `turn_start` is a prompt still
  to run; a `turn_start` with no `turn_end` is a turn that was cut off. Whoever takes the chat
  reads both from the log. A cut turn is continued with a prompt that names the tool call that
  was in flight.
- **The session moves as one file.** Claude Code keeps a session in
  `<config>/projects/<folder slug>/<session id>.jsonl`. The copy carries that file; the other
  machine puts it under its own folder's slug and runs `claude --resume <session id>` there.
- **The laptop stops itself.** With no answer from the store for most of the lease it stops the
  agent's process tree (SIGSTOP), and a laptop that wakes from sleep stops it within a quarter
  second, until the store says whose chat it is. If the Cloud took it, what the laptop wrote
  after its last copy is kept aside, never merged over the Cloud's work.
- **It comes home by itself.** The machine gives the chat back when it is idle, its copy is
  stored and the laptop is asking. The laptop brings the Cloud's copy in, then stores a copy of
  its own; until then Auto cannot be turned off, because the laptop would be behind.

## Run it

On the Cloud machine (store and machine side in one process):

```
./auto cloud --name my-vm            # prints where its token is kept
```

On the laptop, once:

```
./auto login http://<machine>:7717 <token>
```

Then, in a project folder:

```
./auto chat                          # a chat in this folder; type prompts
./auto chat demo -C ~/proj -m "fix the failing test"
```

From any other device with the same `login`:

```
./auto ls                            # every chat and where it runs
./auto status --watch
./auto attach demo                   # follow a chat and send it messages
./auto send demo "also update the README"
./auto new "write a hello world in Go" # a chat that starts in the Cloud
./auto keep demo on|off              # keep it in the Cloud when the laptop is back
./auto off demo
```

In a chat: `/away` acts out a laptop with no network, `/back` ends it, `/keep on|off`, `/off`,
`/on`, `/status`, `/quit`. Closing the lid, or quitting in the middle of a turn, is the real thing: the
Cloud continues once the lease runs out (15 s here; the product uses 45 s).

## Test it

```
python3 tests/journey.py                          # scripted agent, about 20 s
AUTO_TEST_AGENT=claude python3 tests/journey.py   # real Claude Code on both sides, about 3 min
python3 tests/scenarios.py -j 3                   # 20 other ways a laptop goes away, about 4 min
```

The journey runs a store, a machine and a laptop as three processes with their own homes:
the laptop is frozen in the middle of a tool call, the machine finishes the turn, a third
device sends a message, the laptop wakes, the chat comes home with what the Cloud did, and the
next turn on the laptop remembers all of it.

## On a cmux Cloud machine

```
cmux vm new --name auto-demo --json        # prints the machine's id
./vm.sh install VM_ID claude-haiku-5-5     # copies the demo there, starts it, logs this Mac in
./vm.sh relay VM_ID                        # in another terminal: keep it running
./auto chat -C ~/proj                      # the laptop side
AUTO_TEST_STORE_URL=... AUTO_TEST_STORE_TOKEN=... python3 tests/journey.py   # the journey against it
```

Two things about today's Cloud machines shape this:

- **A machine made with `cmux vm new` has no model route.** `claude -p` there answers "Not
  logged in": the name its model calls go to does not resolve. `vm.sh relay` carries the
  machine's model calls back over a connection this Mac opens to it and puts this Mac's
  credential on them here (`autodemo/relay.py`), so nothing secret is put on the machine. The
  machine can then think only while the relay runs: the *chat* leaves the laptop, the model
  route does not. The product needs the machine's own route for the real thing.
- **Only this Mac can reach the machine's ports** (`cmux vm port-forward`, loopback, a new local
  port each time). Publishing a port for a phone is not set up on this deployment, so "another
  device" is a second `AUTO_DEVICE` on the Mac.

`cmux vm exec` ends a command after 25 s, so everything there runs in tmux. A paused machine
runs nothing and nothing wakes it: `vm.sh install` turns its idle pause off.

## What running it showed

Things the scripted agent never showed and real Claude Code, two machines and a slow network
did. Each is worth checking in the product's build of Auto mode.

1. **A turn is not over at the agent's first result.** Headless Claude Code can print a result
   and go on: a command it runs in the background keeps the process alive, and it speaks again
   when that ends. Ending the turn at the first result let the next prompt start a second agent
   on the same session beside the first. Here a turn lasts as long as the agent's process.
2. **The session file moves between versions and systems.** A session started by Claude Code
   2.1.331 on macOS was resumed by 2.1.299 on Linux under another path, and it knew the earlier
   turn. The continuation prompt says where it is now and where it was.
3. **A lost answer must not cost the chat.** A laptop whose lease ran out with nothing to run
   takes its parked chat back; if that answer is lost it asks again with its old epoch and was
   told `lost`, which killed its turn though nobody else had run the chat. The store now
   remembers the epoch a holder's time began (`tenure`) and takes any epoch since. The
   product's core covers one such round (`resumed_epoch`), not two in a row.
4. **A laptop that wakes runs on until somebody notices.** The agent's processes wake with the
   laptop. With the check on the renewal timer they ran for seconds; a quarter-second clock
   that sees the gap stops them at once.
5. **A prompt typed while the chat is on its way home** went to the old holder's inbox and
   stayed there. What was typed for another holder and never delivered now runs here.
6. **Taking a chat and starting its loop both queued the cut turn**, so it ran twice. The log
   is the only queue; a turn that is running is not a cut turn.
7. **The Cloud machine needs a model route of its own.** In production a Cloud chat's model
   credential comes from the owner's Mac with the agent's start, and a machine has no route
   without it. A chat the store starts while the Mac is away has nobody to bring one. The demo
   gets round it with a relay through the Mac, which is not the real thing.
8. **Nothing wakes a paused machine but the app, and a phone cannot reach a machine's port** on
   this deployment. "Asleep until needed" needs a party that is always on (the store's
   `--wake-cmd` is the place for it).
9. **Under a loaded machine, calls to the store took seconds** (5 s timeouts on a Mac at load
   100). The lease times have to carry that: a 4 s lease flaps, 15 s holds.

10. **The self-stop cannot wait behind the renewal.** With the stop decided when a renewal
    fails, a call that hung (no answer at all, rather than a refused connection) kept the
    laptop's agent running up to 3.5 s after the Cloud had the chat. The stop has its own clock
    here, the lease is counted from when the call left, and the agent's process group is
    stopped before the slower walk for a tool's shell in a group of its own.
11. **A store that was down must not read the gap as everybody's lease running out.** After a
    6 s restart the first alarm gave a working laptop's chat to the machine. Each holder gets a
    whole lease from the store's start.
12. **A turn's end must be in the store before the chat can go home.** A holder that says
    "nothing to run" as soon as its agent exits, with the turn's last events unsent, can have
    the chat handed on without them, and the next holder runs the turn again. Unsent events
    count as work here.

## What it leaves out

- One store, one Auto machine, one token for everybody. No accounts, no teams.
- The Cloud machine stays awake. `--wake-cmd` is the hook for "asleep until needed": the store
  runs it when the machine has work and has not asked lately.
- The folder is copied whole (tracked and untracked files and `.git`), up to 512 MB, files up to
  64 MB. No patch against a commit, no merge: the holder's copy wins, and the other side's late
  changes are kept in `leftover/`.
- The agent is headless Claude Code, one process per turn, permissions skipped.
- The store writes a chat's events before its state: a crash between the two is not handled.
- Files the laptop made after its last copy stay in the folder when the Cloud's copy comes
  home (a copy of them is in `leftover/` too); only files of the earlier copy are removed.

## Files

| File | What |
|---|---|
| `autodemo/store.py` | holders, epochs, leases, inbox, assignments; the rules |
| `autodemo/server.py`, `client.py` | the store over HTTP |
| `autodemo/holder.py` | the loop a laptop or the machine runs for one chat |
| `autodemo/copy.py` | the folder and session-file copy |
| `autodemo/agent.py`, `fake_agent.py` | one Claude Code turn; the scripted stand-in for tests |
| `autodemo/ui.py`, `cli.py` | the terminal view and the commands |
