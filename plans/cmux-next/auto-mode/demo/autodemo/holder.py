"""One chat on one machine: the loop that holds it, loses it and gets it back.

The same loop runs on a laptop (`device:<id>`) and on the Auto machine (`vm:<name>`):

- **holding**: it runs the chat's turns, renews the lease, sends events and copies to the
  store, and takes messages from the inbox. A laptop that gets no answer for the self-stop time
  freezes the agent's process tree: the Cloud may be about to run the same chat.
- **standby**: another holder runs the chat. It follows the events, keeps saying it is here,
  and takes the chat back when the store gives it (bringing the Cloud's copy in first).
- **away** (a machine): the chat went home; the next assignment starts it again.

The chat's event log is its queue: a `user` event with no `turn_start` is a prompt still to
run, and a `turn_start` with no `turn_end` is a turn that was cut off. Whoever takes the chat
reads both from the log, so nothing is kept only in one machine's memory.
"""

import json
import os
import socket
import threading
import time
import uuid

from . import agent as agent_mod
from .client import Offline, Refused
from .copy import Copier, TooLarge, session_path


def now_ms():
    return int(time.time() * 1000)


class Chat:
    def __init__(self, client, me, chat_id, folder, home, ui, model=None, title=None,
                 copy_ms=3000):
        self.client = client
        self.me = me
        self.side = "machine" if me.startswith("vm:") else "laptop"
        self.id = chat_id
        self.folder = os.path.realpath(folder)
        self.dir = os.path.join(home, "chats", chat_id)
        self.ui = ui
        self.model = model
        self.title = title or chat_id
        self.copy_ms = copy_ms
        self.lock = threading.RLock()
        self.wake = threading.Event()
        self.dirty = threading.Event()
        self.work = threading.Event()
        self.closing = False
        self.copier = Copier(client, self.folder)
        # What is kept on disk.
        self.sid = agent_mod.new_session_id()
        self.epoch = 0
        self.seq = 0
        self.sent_seq = 0
        self.snapshot = 0
        self.stored_files = None
        self.inbox_taken = 0
        self.events = []
        # What is not.
        self.mode = "registering"
        self.stopped = False
        self.stop_why = ""
        self.turn = None
        self.running = None
        self.pending = []
        self.open_turn = None
        self.moved = None
        self.view = None
        self.timing = {"lease_ms": 15000, "renew_ms": 3000, "self_stop_ms": 11000}
        self.last_answer = time.monotonic()
        self.last_copy = 0.0
        self.force_copy = False
        self.repost = []
        self.blocked = None
        self.threads = []
        os.makedirs(self.dir, exist_ok=True)
        self._load()

    # ---- what is kept on disk ----

    def _load(self):
        try:
            with open(os.path.join(self.dir, "state.json")) as f:
                state = json.load(f)
        except (OSError, ValueError):
            return
        for key in ("sid", "epoch", "seq", "sent_seq", "snapshot", "stored_files", "inbox_taken"):
            if key in state:
                setattr(self, key, state[key])
        if state.get("folder"):
            self.folder = state["folder"]
            self.copier = Copier(self.client, self.folder)
        try:
            with open(os.path.join(self.dir, "events.jsonl")) as f:
                self.events = [json.loads(line) for line in f if line.strip()]
        except OSError:
            self.events = []
        self.events = [e for e in self.events if e["seq"] <= self.seq]
        if self.epoch:
            # It held the chat when it last ran: ask before anything runs.
            self.mode = "holding"
            self.stopped = True

    def known(self):
        return self.epoch > 0 or bool(self.events)

    def _save(self):
        state = {"id": self.id, "sid": self.sid, "epoch": self.epoch, "seq": self.seq,
                 "sent_seq": self.sent_seq, "snapshot": self.snapshot,
                 "stored_files": self.stored_files, "inbox_taken": self.inbox_taken,
                 "folder": self.folder, "title": self.title}
        tmp = os.path.join(self.dir, "state.json.tmp")
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, os.path.join(self.dir, "state.json"))

    def _rewrite_journal(self):
        tmp = os.path.join(self.dir, "events.jsonl.tmp")
        with open(tmp, "w") as f:
            for event in self.events:
                f.write(json.dumps(event) + "\n")
        os.replace(tmp, os.path.join(self.dir, "events.jsonl"))

    def _append(self, event):
        self.events.append(event)
        with open(os.path.join(self.dir, "events.jsonl"), "a") as f:
            f.write(json.dumps(event) + "\n")

    # ---- events ----

    def emit(self, kind, render=True, **fields):
        """One more event of this chat, by this holder. Dropped when the chat is not held here
        any more (a killed turn's last words)."""
        with self.lock:
            if self.mode not in ("holding", "off", "registering"):
                return None
            self.seq += 1
            event = {"seq": self.seq, "at": now_ms(), "by": self.me, "kind": kind}
            event.update(fields)
            self._append(event)
            self._save()
        if render:
            self.ui.event(event)
        self.dirty.set()
        return event

    def _derive(self):
        """The prompts still to run and the turn that was cut off, from the log."""
        started, ended, users, tools = [], set(), {}, {}
        order = []
        for e in self.events:
            kind = e["kind"]
            if kind == "user":
                users[e["id"]] = e
                order.append(e["id"])
            elif kind == "turn_start":
                started.append(e["id"])
                tools[e["id"]] = None
            elif kind == "turn_end":
                ended.add(e["id"])
            elif kind == "tool" and started:
                tools[started[-1]] = e.get("label")
            elif kind == "tool_result" and started:
                tools[started[-1]] = None
        open_turn = None
        for pid in started:
            if pid not in ended and pid in users:
                open_turn = {"id": pid, "text": users[pid]["text"], "tool": tools.get(pid)}
        pending = [users[pid] for pid in order if pid not in started]
        return open_turn, pending

    def _requeue(self, why):
        with self.lock:
            open_turn, pending = self._derive()
            if open_turn and open_turn["id"] == self.running:
                open_turn = None
            self.open_turn = open_turn
            self.pending = [{"id": e["id"], "text": e["text"]} for e in pending]
            if self.open_turn:
                self.open_turn["why"] = why
        self.work.set()

    # ---- what the person does ----

    def submit(self, text):
        """A prompt typed on this machine."""
        pid = "p-" + uuid.uuid4().hex[:12]
        if self.mode in ("holding", "off", "registering"):
            event = self.emit("user", id=pid, text=text, sender=self.me)
            if event is not None:
                with self.lock:
                    self.pending.append({"id": pid, "text": text})
                self.work.set()
                return "queued" if self.busy() else "running"
        # Another holder has the chat: the message goes to its inbox.
        self.repost.append({"id": pid, "text": text})
        self.wake.set()
        return "sent"

    def busy(self):
        return self.turn is not None

    def set_keep(self, keep):
        return self.client.keep(self.id, keep)

    def turn_off(self):
        """Auto off. Refused while the Cloud has work this laptop does not."""
        answer = self.client.put(self.id, {"auto": False})
        with self.lock:
            self.mode = "off"
        return answer

    def turn_on(self):
        """Auto on again for a chat it was turned off for."""
        with self.lock:
            if self.mode == "off":
                self.mode = "registering"
        self.wake.set()

    # ---- threads ----

    def start(self):
        if self.events and self.mode == "holding" and not self.pending and not self.open_turn:
            self._requeue("restart")
        for target in (self._renew_loop, self._work_loop, self._copy_loop, self._mirror_loop,
                       self._clock_loop):
            thread = threading.Thread(target=self._guard, args=(target,), daemon=True)
            thread.start()
            self.threads.append(thread)

    def _guard(self, target):
        while not self.closing:
            try:
                target()
                return
            except Exception as error:  # a loop never dies of one bad answer
                self.ui.note("error in %s: %r" % (target.__name__, error))
                time.sleep(1)

    def close(self, final_copy=True):
        """This machine stops running the chat. A turn that was running goes on in the Cloud
        once the lease runs out."""
        turn = self.turn
        if turn is not None:
            turn.kill()
        if final_copy and self.mode == "holding" and not self.stopped and self.epoch:
            try:
                self._flush_events()
                self._copy()
            except (Offline, Refused, TooLarge, OSError):
                pass
        self.closing = True
        self.wake.set()
        self.dirty.set()
        self.work.set()

    # ---- the lease ----

    def _renew_loop(self):
        while not self.closing:
            self._renew_once()
            self.ui.status(self.status_line())
            period = 1.0 if self.mode == "registering" else self.timing["renew_ms"] / 1000.0
            self.wake.wait(period)
            self.wake.clear()

    def _clock_loop(self):
        """A laptop that slept (or a process that was frozen) wakes with its agent running again.
        A gap between two ticks of this clock says so within a quarter second, and the agent is
        stopped until the store says whose chat it is."""
        if self.side != "laptop":
            return
        wall, mono = time.time(), time.monotonic()
        while not self.closing:
            time.sleep(0.25)
            wall2, mono2 = time.time(), time.monotonic()
            gap = max(wall2 - wall, mono2 - mono)
            wall, mono = wall2, mono2
            if self.mode != "holding":
                continue
            if gap > 2.0:
                self._freeze("this laptop was asleep for %ds" % gap)
                self.wake.set()
            elif mono2 - self.last_answer > self.timing["self_stop_ms"] / 1000.0:
                # Not left to the renewal: a call that hangs would keep the agent running
                # past the moment the Cloud may start the same chat.
                self._freeze("no answer from the Cloud for %ds" % (mono2 - self.last_answer))

    def _freeze(self, why):
        with self.lock:
            if self.stopped:
                return
            self.stopped = True
            self.stop_why = why
            if self.turn is not None:
                self.turn.stop()
        self.ui.note("%s: the agent is stopped until the Cloud answers" % why)

    def _unfreeze(self):
        with self.lock:
            if not self.stopped:
                return
            self.stopped = False
            if self.turn is not None:
                self.turn.cont()
        self.work.set()
        self.dirty.set()

    def _renew_once(self):
        try:
            if self.mode == "registering":
                self._register()
            elif self.mode == "holding":
                self._renew_holding()
            elif self.mode == "standby":
                self._renew_standby()
        except Offline as error:
            if os.environ.get("AUTO_DEBUG"):
                self.ui.note("no answer (%s): %s" % (self.mode, error))
            waited = time.monotonic() - self.last_answer
            if (self.side == "laptop" and self.mode == "holding"
                    and waited > self.timing["self_stop_ms"] / 1000.0):
                self._freeze("no answer from the Cloud for %ds" % waited)
        except Refused as refused:
            if refused.code == "closed":
                self._closed()
            elif refused.code != "not_found" or os.environ.get("AUTO_DEBUG"):
                self.ui.note("the Cloud refused: %s" % refused)

    def _answered(self, answer, began=None):
        # The store's lease runs from when it got the call, not from when its answer came.
        self.last_answer = began if began is not None else time.monotonic()
        if answer.get("timing"):
            self.timing = answer["timing"]
        if answer.get("chat"):
            self.view = answer["chat"]

    def _register(self):
        answer = self.client.put(self.id, {"auto": True, "device": self.me, "title": self.title,
                                           "cwd": self.folder})
        self._answered(answer)
        view = answer["chat"]
        with self.lock:
            if view["holder"] == self.me:
                self.epoch = view["epoch"]
                self.mode = "holding"
                self._save()
            else:
                # Somebody else has it: what was typed here goes to its inbox.
                for event in self.events:
                    if event["seq"] > self.sent_seq and event["kind"] == "user":
                        self.repost.append({"id": event["id"], "text": event["text"]})
                self.events = [e for e in self.events if e["seq"] <= self.sent_seq]
                self.seq = self.sent_seq
                self._rewrite_journal()
                self.pending, self.open_turn = [], None
                self.mode = "standby"
                self._save()
        if self.mode == "standby":
            self.ui.note("this chat is %s; it comes here when its turn ends" % where(view))
        self.work.set()
        self.dirty.set()
        self.wake.set()

    def _renew_holding(self):
        # A turn whose last events have not reached the store is still work: the chat must
        # not be handed on without them.
        needs_run = (self.running is not None or self.turn is not None or bool(self.pending)
                     or self.open_turn is not None or self.sent_seq < self.seq)
        began = time.monotonic()
        answer = self.client.lease(self.id, self.me, self.epoch, needs_run,
                                   timeout=max(2.0, self.timing["self_stop_ms"] / 2000.0))
        self._answered(answer, began)
        if answer["role"] != "holder":
            return self._lose(answer["chat"])
        view = answer["chat"]
        with self.lock:
            if view["epoch"] != self.epoch:
                self.epoch = view["epoch"]
                self._save()
        self._unfreeze()
        self._drain_repost()
        if view["inbox_n"] > self.inbox_taken:
            self._take_inbox()

    def _drain_repost(self):
        """What was typed here while another holder had the chat, and never reached it: this
        machine holds the chat now, so it runs here."""
        while self.repost and self.mode == "holding":
            message = self.repost.pop(0)
            with self.lock:
                if any(e["kind"] == "user" and e["id"] == message["id"] for e in self.events):
                    continue
            if self.emit("user", id=message["id"], text=message["text"], sender=self.me, render=False):
                with self.lock:
                    self.pending.append(message)
                self.work.set()

    def _renew_standby(self):
        answer = self.client.lease(self.id, self.me, self.epoch, False, standby=True)
        self._answered(answer)
        if answer["role"] == "holder":
            return self._come_home(answer)
        if self.repost:
            for message in list(self.repost):
                self.client.post_inbox(self.id, message["id"], message["text"], self.me)
                self.repost.remove(message)

    def _closed(self):
        with self.lock:
            was = self.mode
            self.mode = "off"
        # Nobody else can run the chat now: what was stopped here goes on.
        self._unfreeze()
        if was != "off":
            self.ui.note("Auto is off for this chat: it runs only here")

    def _lose(self, view):
        """Another holder has the chat. Kill what runs here, keep what it wrote after the last
        stored copy, and stand by."""
        with self.lock:
            if self.mode != "holding":
                return
            self.mode = "standby" if self.side == "laptop" else "away"
            turn = self.turn
            self.stopped = False
            unsent = [e for e in self.events if e["seq"] > self.sent_seq]
            self.events = [e for e in self.events if e["seq"] <= self.sent_seq]
            self.seq = self.sent_seq
            self._rewrite_journal()
            self.pending, self.open_turn = [], None
            self._save()
        if turn is not None:
            turn.kill()
        if self.side == "machine":
            self.ui.note("%s went home (%s)" % (self.id, where(view)))
            return
        for event in unsent:
            if event["kind"] == "user" and event.get("sender") == self.me:
                self.repost.append({"id": event["id"], "text": event["text"]})
        kept = []
        if self.stored_files is not None:
            dest = os.path.join(self.dir, "leftover", time.strftime("%Y%m%d-%H%M%S"))
            kept = self.copier.leftover(self.stored_files, dest)
        if view.get("holder") == self.me:
            self.ui.note("this chat ran in the Cloud while this laptop was away: bringing its copy in")
        else:
            self.ui.note("the Cloud took this chat (%s)" % where(view))
        if kept:
            self.ui.note("%d file(s) changed here after the last copy were kept in %s"
                         % (len(kept), dest))
        self.wake.set()

    def _come_home(self, answer):
        """The store gave the chat to this laptop: bring the Cloud's copy in, then hold."""
        view = answer["chat"]
        self._mirror_until(view["last_seq"])
        if answer.get("import"):
            try:
                snap = self.client.snapshot(self.id)
            except Refused as refused:
                if refused.code != "no_snapshot":
                    raise
                snap = None
            if snap:
                manifest = snap["manifest"]
                self.copier.bring(manifest, previous_files=self.stored_files)
                with self.lock:
                    if manifest.get("session"):
                        self.sid = manifest["session"]["id"]
                    self.stored_files = manifest["files"]
                    self.snapshot = snap["snapshot"]
                    if manifest.get("cwd") != self.folder:
                        self.moved = manifest.get("cwd")
        with self.lock:
            self.epoch = view["epoch"]
            self.inbox_taken = max(self.inbox_taken, view["inbox_acked"])
            self.mode = "holding"
            self.stopped = False
            self._save()
        self._requeue("handback")
        self.force_copy = True
        self.dirty.set()
        self.ui.note("the chat is back on this machine")

    # ---- the inbox ----

    def _take_inbox(self):
        """Messages become events of the chat, the events reach the store, then the inbox is
        acked: a holder that dies after the ack has lost nothing."""
        messages = self.client.inbox(self.id, self.inbox_taken)
        if not messages:
            return
        known = set(e["id"] for e in self.events if e["kind"] == "user")
        for message in messages:
            if message["id"] not in known:
                self.emit("user", id=message["id"], text=message["text"], sender=message.get("from"))
                with self.lock:
                    self.pending.append({"id": message["id"], "text": message["text"]})
        self._flush_events()
        last = messages[-1]["n"]
        self.client.ack_inbox(self.id, self.me, self.epoch, last)
        with self.lock:
            self.inbox_taken = last
            self._save()
        self.work.set()

    # ---- turns ----

    def _work_loop(self):
        while not self.closing:
            self.work.wait(1.0)
            self.work.clear()
            while not self.closing:
                with self.lock:
                    ready = (self.mode in ("holding", "off") and not self.stopped
                             and self.turn is None)
                    job = None
                    if ready and self.open_turn:
                        job, self.open_turn = dict(self.open_turn, cut=True), None
                    elif ready and self.pending:
                        job = self.pending.pop(0)
                    if job is not None:
                        self.running = job["id"]
                if job is None:
                    break
                try:
                    self._run_turn(job)
                finally:
                    self.running = None

    def _prompt_for(self, job):
        here = "%s; the project folder is %s" % (socket.gethostname(), self.folder)
        moved, self.moved = self.moved, None
        if job.get("cut"):
            reasons = {"takeover": "the computer it was running on went away",
                       "restart": "the program running it was closed",
                       "handback": "the machine running it stopped"}
            lines = ["[cmux Auto] Your last turn was cut off before it finished: %s." % reasons.get(job.get("why"), "it was interrupted"),
                     "You are now on %s%s." % (here, " (it was %s)" % moved if moved else ""),
                     "The request was:", "", job["text"], ""]
            if job.get("tool"):
                lines.append("A tool call was in flight when it was cut (%s). Its result is unknown: "
                             "check what it already did before you run it again." % job["tool"])
            lines.append("Continue the request from where it stopped.")
            return "\n".join(lines)
        if moved:
            return ("[cmux Auto] This chat moved to another machine. You are now on %s (it was %s).\n\n%s"
                    % (here, moved, job["text"]))
        return job["text"]

    def _run_turn(self, job):
        if job.get("cut"):
            started = self.emit("note", text="continuing the turn that was cut off")
        else:
            started = self.emit("turn_start", id=job["id"], render=False)
        if started is None:
            return
        prompt = self._prompt_for(job)
        resume = os.path.exists(session_path(self.folder, self.sid))
        try:
            turn = agent_mod.Turn(self.folder, self.sid, resume, prompt, self.model)
        except (OSError, RuntimeError) as error:
            self.emit("turn_end", id=job["id"], ok=False, error=str(error))
            return
        with self.lock:
            self.turn = turn
            if self.stopped:
                turn.stop()
        self.wake.set()
        ok, error = True, None
        for ev in turn.events():
            if ev[0] == "delta":
                if self.mode in ("holding", "off"):
                    self.ui.delta(ev[1])
            elif ev[0] == "text":
                self.emit("text", text=ev[1], render=not ev[2])
                if ev[2]:
                    self.ui.end_delta()
            elif ev[0] == "tool":
                self.emit("tool", tool=ev[1], label=ev[2])
            elif ev[0] == "tool_result":
                self.emit("tool_result", tool=ev[1], ok=ev[2], label=ev[3])
            elif ev[0] == "end":
                ok, error = ev[1], (None if ev[1] else ev[2])
        with self.lock:
            self.turn = None
        if turn.killed:
            return
        self.emit("turn_end", id=job["id"], ok=ok, error=error)
        self.force_copy = True
        self.dirty.set()
        self.wake.set()

    # ---- the copy ----

    def _flush_events(self):
        while True:
            with self.lock:
                batch = [e for e in self.events if e["seq"] > self.sent_seq][:200]
                epoch = self.epoch
            if not batch:
                return
            try:
                answer = self.client.append_events(self.id, self.me, epoch, batch)
            except Refused as refused:
                if refused.code != "seq_gap":
                    raise
                answer = {"last_seq": refused.body.get("last_seq", 0)}
            with self.lock:
                self.sent_seq = min(answer["last_seq"], self.seq)
                self._save()

    def _copy_loop(self):
        while not self.closing:
            self.dirty.wait(self.copy_ms / 1000.0)
            self.dirty.clear()
            if self.closing or self.mode != "holding" or self.stopped or not self.epoch:
                continue
            try:
                self._flush_events()
                due = time.monotonic() - self.last_copy >= self.copy_ms / 1000.0
                behind = self.view is None or self.view.get("snapshot_seq") != self.seq or not self.snapshot
                if self.force_copy or (due and (self.turn is not None or behind)):
                    self._copy()
            except Offline:
                pass
            except Refused as refused:
                if refused.code in ("not_holder", "stale_epoch", "closed"):
                    self.wake.set()
                else:
                    self.ui.note("the copy was refused: %s" % refused)
            except TooLarge as error:
                if self.blocked != "too_large":
                    self.blocked = "too_large"
                    self.ui.note("this chat cannot move to the Cloud: %s" % error)

    def _copy(self):
        self.force_copy = False
        with self.lock:
            seq, epoch, sid = self.sent_seq, self.epoch, self.sid
        manifest, _uploaded = self.copier.export(sid, seq, {"title": self.title})
        answer = self.client.post_snapshot(self.id, self.me, epoch, manifest)
        with self.lock:
            self.snapshot = answer["snapshot"]
            self.stored_files = manifest["files"]
            self.last_copy = time.monotonic()
            if self.view is not None:
                self.view["snapshot"] = answer["snapshot"]
                self.view["snapshot_seq"] = answer["snapshot_seq"]
            self._save()
        if self.seq != seq:
            self.dirty.set()
        self.wake.set()

    # ---- following another holder ----

    def _mirror_loop(self):
        while not self.closing:
            if self.mode != "standby":
                time.sleep(0.3)
                continue
            try:
                self._mirror(wait_ms=10000)
            except (Offline, Refused):
                time.sleep(1)

    def _mirror(self, wait_ms=0):
        answer = self.client.events(self.id, self.seq, wait_ms)
        with self.lock:
            if self.mode not in ("standby", "taking"):
                return answer
            for event in answer["events"]:
                if event["seq"] != self.seq + 1:
                    continue
                self.seq = self.sent_seq = event["seq"]
                self._append(event)
                self.ui.event(event)
            self._save()
        if answer.get("chat") and (self.view is None or answer["chat"]["version"] != self.view["version"]):
            self.view = answer["chat"]
            self.wake.set()
        return answer

    def _mirror_until(self, last_seq):
        tries = 0
        while self.seq < last_seq and tries < 50:
            self._mirror()
            tries += 1

    # ---- a machine starting on an assignment ----

    def take(self, assignment):
        """The Auto machine's start: the log and the copy come from the store, the cut turn and
        the unread messages become this machine's work."""
        with self.lock:
            turn, self.turn = self.turn, None
            self.epoch = assignment["epoch"]
            self.mode = "taking"
            # The whole log, as the store has it.
            self.events, self.seq, self.sent_seq = [], 0, 0
            self.pending, self.open_turn = [], None
            self._rewrite_journal()
        if turn is not None:
            turn.kill()
        view = self.client.chat(self.id)
        self._mirror_until(view["last_seq"])
        moved = None
        if view["snapshot"]:
            snap = self.client.snapshot(self.id)
            manifest = snap["manifest"]
            self.copier.bring(manifest, previous_files=self.stored_files)
            with self.lock:
                if manifest.get("session"):
                    self.sid = manifest["session"]["id"]
                self.stored_files = manifest["files"]
                self.snapshot = snap["snapshot"]
                moved = manifest.get("cwd")
        else:
            os.makedirs(self.folder, exist_ok=True)
        with self.lock:
            self.view = view
            self.title = view["title"]
            self.inbox_taken = view["inbox_acked"]
            self.moved = moved if moved != self.folder else None
            self.mode = "holding"
            self.stopped = False
            self.last_answer = time.monotonic()
            self._save()
        self._requeue("takeover")
        self.client.ack_assignment(self.id, self.me, self.epoch)
        if assignment["kind"] == "takeover":
            self.emit("note", text="running in the Cloud on %s: the laptop went away" % self.me[3:])
        self._take_inbox()
        self.force_copy = True
        self.dirty.set()
        self.wake.set()

    def deliver(self, assignment):
        """A message for a chat this machine holds already."""
        self.client.ack_assignment(self.id, self.me, self.epoch)
        self._take_inbox()
        self.wake.set()

    # ---- what the bar says ----

    def status_line(self):
        view = self.view or {}
        if self.mode == "off":
            return "Auto off"
        if self.mode == "registering":
            return "Auto: reaching the Cloud..."
        waited = time.monotonic() - self.last_answer
        if self.mode == "holding":
            if self.stopped:
                return "Auto  ||  %s: agent stopped until the Cloud answers" % (self.stop_why or "no answer")
            lease = self.timing["lease_ms"] / 1000.0
            left = max(0, int(lease - waited))
            copy = ("copy #%d" % self.snapshot) if self.snapshot else "no copy yet"
            doing = "working" if self.turn is not None else "idle"
            where_ = "here" if self.side == "laptop" else "in the Cloud (%s)" % self.me[3:]
            return "Auto  *  %s, %s  |  lease %2ds  |  %s  |  epoch %d" % (where_, doing, left, copy, self.epoch)
        if self.mode == "standby":
            state = view.get("state")
            if state == "resuming":
                return "Auto  ~  resuming in the Cloud..."
            if state == "cloud":
                tail = "stays there" if view.get("keep_in_cloud") else (
                    "comes back when this turn ends" if view.get("needs_run") else "coming back")
                return "Auto  @  running in the Cloud on %s  |  %s" % (view.get("holder", "")[3:], tail)
            return "Auto  ~  %s" % where(view)
        return "Auto: %s" % self.mode


def where(view):
    holder = view.get("holder", "")
    if holder.startswith("vm:"):
        return "in the Cloud on %s" % holder[3:]
    if holder.startswith("device:"):
        return "on %s" % holder[7:]
    return "parked in the Cloud"
