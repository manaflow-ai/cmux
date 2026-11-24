"""The Cloud store: who holds each chat, its lease, its copy and its inbox.

Rules (the product design's, kept small):

- A chat has one holder: `device:<id>` (a laptop), `vm:<name>` (the Auto machine) or `parked`.
  The epoch grows by one at every change of holder. Every write by a holder names its holder
  and epoch and is refused when either is old.
- A laptop renews its lease. When the lease runs out, a chat with work (a turn running, or a
  message nobody read) goes to the Auto machine with an assignment, if the store has a copy to
  start from. An idle chat is parked.
- A laptop that comes back renews as a standby. The machine gives the chat home at its own
  renewal once it is idle, everything is read and the newest copy is stored.
- A laptop that was given a chat it did not hold last must bring the copy in first
  (`import: true` in the answer); until it stored a copy of its own, Auto cannot be turned off.
- A message goes to the chat's inbox from any device. The holder reads it, makes it durable,
  acks it, then runs it.

State is kept in one folder (state.json, events/<chat>.jsonl, blobs/<sha256>), so the store
can restart.
"""

import hashlib
import json
import os
import subprocess
import threading
import time

PARKED = "parked"


def is_vm(holder):
    return holder.startswith("vm:")


def is_device(holder):
    return holder.startswith("device:")


class Refused(Exception):
    """An answer that is not 2xx: `{error: {code, message}, chat?}`."""

    def __init__(self, status, code, message, **extra):
        Exception.__init__(self, message)
        self.status, self.code, self.message, self.extra = status, code, message, extra

    def body(self):
        body = {"error": {"code": self.code, "message": self.message}}
        body.update(self.extra)
        return body


STALL_MS = 3000


def steady_clock():
    """Milliseconds that never step: a lease must not get longer or shorter because the
    machine's wall clock was set."""
    wall, mono = time.time(), time.monotonic()
    return lambda: int((wall + time.monotonic() - mono) * 1000)


class Store:
    def __init__(self, root, lease_ms=15000, wake_cmd=None, clock=None):
        self.root = root
        self.lease_ms = lease_ms
        self.wake_cmd = wake_cmd
        self.clock = clock or steady_clock()
        self.cv = threading.Condition()
        self.chats = {}
        self.machine = None  # {"name", "seen_at"}
        self.woke_at = 0
        self.wakes = 0
        self.ticked_at = None
        self.stalls = 0
        os.makedirs(os.path.join(root, "events"), exist_ok=True)
        os.makedirs(os.path.join(root, "blobs"), exist_ok=True)
        self._load()

    # ---- timing, told to every caller so nobody guesses ----

    def timing(self):
        return {
            "lease_ms": self.lease_ms,
            "renew_ms": max(500, self.lease_ms * 10 // 45),
            "self_stop_ms": self.lease_ms * 35 // 45,
        }

    # ---- persistence ----

    def _state_path(self):
        return os.path.join(self.root, "state.json")

    def _load(self):
        try:
            with open(self._state_path()) as f:
                state = json.load(f)
        except (OSError, ValueError):
            return
        self.chats = state.get("chats", {})
        self.machine = state.get("machine")
        # No holder could renew while the store was down: each gets a whole lease from now.
        now = self.clock()
        for r in self.chats.values():
            if r.get("auto") and r.get("holder") != PARKED:
                r["lease_expires"] = max(r.get("lease_expires", 0), now + self.lease_ms)
        if self.machine:
            self.machine["seen_at"] = max(self.machine.get("seen_at", 0), now)

    def _save(self):
        tmp = self._state_path() + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"chats": self.chats, "machine": self.machine}, f)
        os.replace(tmp, self._state_path())

    def _changed(self, r):
        r["version"] += 1
        r["updated_at"] = self.clock()
        self._save()
        self.cv.notify_all()

    def _events_path(self, chat_id):
        return os.path.join(self.root, "events", chat_id + ".jsonl")

    def _blob_path(self, sha):
        if len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha):
            raise Refused(400, "invalid_request", "not a sha256")
        return os.path.join(self.root, "blobs", sha)

    # ---- the view every caller gets ----

    def view(self, r):
        now = self.clock()
        holder = r["holder"]
        assignment = r.get("assignment")
        if not r["auto"]:
            state = "off"
        elif holder == PARKED:
            state = "parked"
        elif is_vm(holder):
            state = "resuming" if assignment and not assignment["acked"] else "cloud"
        else:
            state = "local"
        blocked = None
        work = r["needs_run"] or self._unread(r)
        if r["auto"] and not is_vm(holder) and work:
            if not self.machine:
                blocked = "no_machine"
            elif not r["snapshot"]:
                blocked = "no_copy"
        standby = r.get("standby")
        return {
            "id": r["id"],
            "title": r["title"],
            "auto": r["auto"],
            "holder": holder,
            "epoch": r["epoch"],
            "state": state,
            "blocked": blocked,
            "needs_run": r["needs_run"],
            "keep_in_cloud": r["keep_in_cloud"],
            "last_seq": r["last_seq"],
            "snapshot": r["snapshot"],
            "snapshot_seq": r["snapshot_seq"],
            "inbox_n": len(r["inbox"]),
            "inbox_acked": r["inbox_acked"],
            "lease_left_ms": max(0, r["lease_expires"] - now) if holder != PARKED else 0,
            "standby": standby["device"] if standby and self._fresh(standby, now) else None,
            "move": r.get("move"),
            "cwd": r.get("cwd"),
            "home": r.get("home"),
            "version": r["version"],
            "created_at": r["created_at"],
            "updated_at": r["updated_at"],
        }

    def _unread(self, r):
        return len(r["inbox"]) > r["inbox_acked"]

    def _fresh(self, standby, now):
        return now - standby["at"] < self.lease_ms

    def _chat(self, chat_id):
        r = self.chats.get(chat_id)
        if r is None:
            raise Refused(404, "not_found", "no such chat")
        return r

    def _fence(self, r, holder, epoch):
        if not r["auto"]:
            raise Refused(409, "closed", "Auto is off for this chat", chat=self.view(r))
        if holder != r["holder"]:
            raise Refused(409, "not_holder", "another holder has this chat", chat=self.view(r))
        if epoch != r["epoch"]:
            raise Refused(409, "stale_epoch", "the chat moved on", chat=self.view(r))

    # ---- holder changes ----

    def _take(self, r, holder, owes, now):
        # A laptop taking back the chat it parked, with nobody running it in between, goes on
        # with what it has: its time as holder (`tenure`) started at an earlier epoch.
        same = r["holder"] == PARKED and r.get("parked_from") == holder and not owes
        r["holder"] = holder
        r["epoch"] += 1
        if not same:
            r["tenure"] = r["epoch"]
        r["lease_expires"] = now + self.lease_ms
        r["owes_import"] = owes
        r["parked_from"] = None
        r["assignment"] = None
        r["needs_run"] = False
        r["move"] = None
        if is_device(holder):
            r["home"] = holder

    def _park(self, r, parked_from):
        r["holder"] = PARKED
        r["epoch"] += 1
        r["parked_from"] = parked_from
        r["owes_import"] = False
        r["needs_run"] = False

    def _to_machine(self, r, kind, now):
        r["holder"] = "vm:" + self.machine["name"]
        r["epoch"] += 1
        r["tenure"] = r["epoch"]
        # Time for the machine to wake and say it has the chat.
        r["lease_expires"] = now + 4 * self.lease_ms
        r["assignment"] = {"kind": kind, "epoch": r["epoch"], "acked": False}
        r["parked_from"] = None
        r["owes_import"] = False
        r["move"] = None
        self._wake(now)

    def _wake(self, now):
        """The machine has work. A paused machine is resumed by the hook; a running one sees
        its held request answered."""
        seen = self.machine and now - self.machine["seen_at"] < 40000
        if seen or not self.wake_cmd or now - self.woke_at < self.lease_ms:
            return
        self.woke_at = now
        self.wakes += 1
        threading.Thread(target=self._run_wake, daemon=True).start()

    def _run_wake(self):
        try:
            subprocess.run(self.wake_cmd, shell=True, timeout=120)
        except (OSError, subprocess.SubprocessError):
            pass

    def tick(self):
        """The lease alarm. Runs before every call and on a timer."""
        now = self.clock()
        if self.ticked_at is not None and now - self.ticked_at > STALL_MS:
            # The alarm runs twice a second. A gap this long means this machine stood still (a
            # Cloud machine can, for tens of seconds): nobody could renew meanwhile, so each
            # holder gets a whole lease from now, as after a restart.
            self.stalls += 1
            for r in self.chats.values():
                if r["auto"] and r["holder"] != PARKED:
                    r["lease_expires"] = max(r.get("lease_expires", 0), now + self.lease_ms)
        self.ticked_at = now
        for r in self.chats.values():
            if not r["auto"]:
                continue
            holder = r["holder"]
            if holder == PARKED:
                if self._unread(r) and r["snapshot"] and self.machine:
                    self._to_machine(r, "deliver", now)
                    self._changed(r)
                continue
            if now < r["lease_expires"]:
                continue
            if is_device(holder):
                work = r["needs_run"] or self._unread(r)
                if work and r["snapshot"] and self.machine:
                    self._to_machine(r, "takeover", now)
                else:
                    self._park(r, None if r["owes_import"] else holder)
                self._changed(r)
            else:
                standby = r.get("standby")
                if standby and self._fresh(standby, now) and not r["keep_in_cloud"]:
                    self._take(r, standby["device"], True, now)
                else:
                    # The machine went quiet with the chat: it starts again from the copy.
                    kind = (r.get("assignment") or {}).get("kind") or "takeover"
                    r["assignment"] = {"kind": kind, "epoch": r["epoch"], "acked": False}
                    r["lease_expires"] = now + 4 * self.lease_ms
                    self._wake(now)
                self._changed(r)

    # ---- owner routes ----

    def status(self):
        now = self.clock()
        machine = None
        if self.machine:
            machine = {
                "name": self.machine["name"],
                "seen_ms_ago": now - self.machine["seen_at"],
                "awake": now - self.machine["seen_at"] < 40000,
            }
        return {"now": now, "machine": machine, "wakes": self.wakes, "timing": self.timing(),
                "chats": len(self.chats)}

    def put(self, chat_id, body):
        """Auto on (registers the chat, or renews as its holder) or off."""
        now = self.clock()
        r = self.chats.get(chat_id)
        if body.get("auto") is False:
            if r is None:
                raise Refused(404, "not_found", "no such chat")
            if r["auto"] and (is_vm(r["holder"]) or r["owes_import"]):
                raise Refused(409, "held_in_cloud",
                              "the Cloud has work this laptop does not have yet; "
                              "turn Auto off once the chat is back", chat=self.view(r))
            if r["auto"]:
                r["auto"] = False
                r["epoch"] += 1
                r["holder"] = PARKED
                r["assignment"] = None
                self._changed(r)
            return {"chat": self.view(r)}
        device = body.get("device")
        if not device or not is_device(device):
            raise Refused(400, "invalid_request", "device must be device:<id>")
        if r is None:
            r = self._new(chat_id, body.get("title") or chat_id, now)
            r["holder"] = device
            r["home"] = device
            r["epoch"] = 1
            r["tenure"] = 1
            r["lease_expires"] = now + self.lease_ms
            r["cwd"] = body.get("cwd")
            self.chats[chat_id] = r
            self._changed(r)
        elif not r["auto"]:
            r["auto"] = True
            self._take(r, device, False, now)
            self._changed(r)
        elif r["holder"] == device:
            r["lease_expires"] = now + self.lease_ms
            self._save()
        elif r["holder"] == PARKED and r["parked_from"] == device:
            self._take(r, device, False, now)
            self._changed(r)
        if "keep_in_cloud" in body and r["keep_in_cloud"] != bool(body["keep_in_cloud"]):
            r["keep_in_cloud"] = bool(body["keep_in_cloud"])
            self._changed(r)
        return {"chat": self.view(r), "timing": self.timing()}

    def _new(self, chat_id, title, now):
        return {
            "id": chat_id, "title": title, "auto": True, "holder": PARKED, "epoch": 0,
            "lease_expires": 0, "needs_run": False, "keep_in_cloud": False,
            "last_seq": 0, "snapshot": 0, "snapshot_seq": 0, "manifest": None,
            "inbox": [], "inbox_acked": 0, "assignment": None, "standby": None,
            "parked_from": None, "owes_import": False, "cwd": None, "home": None, "move": None,
            "version": 0, "created_at": now, "updated_at": now,
        }

    def create(self, body):
        """A new chat from a device with no laptop: it starts on the Auto machine."""
        now = self.clock()
        if not self.machine:
            raise Refused(409, "no_machine", "no Auto machine has connected to this store yet")
        message = body.get("message") or {}
        if not message.get("id") or not message.get("text"):
            raise Refused(400, "invalid_request", "message needs id and text")
        chat_id = body.get("id") or ("c" + hashlib.sha256(message["id"].encode()).hexdigest()[:10])
        if chat_id in self.chats:
            return {"chat": self.view(self.chats[chat_id])}
        r = self._new(chat_id, body.get("title") or message["text"][:48], now)
        r["inbox"].append({"n": 1, "id": message["id"], "text": message["text"],
                           "at": now, "from": body.get("from") or "phone"})
        self.chats[chat_id] = r
        self._to_machine(r, "create", now)
        self._changed(r)
        return {"chat": self.view(r)}

    def list(self):
        chats = sorted(self.chats.values(), key=lambda r: -r["updated_at"])
        return {"chats": [self.view(r) for r in chats]}

    def get(self, chat_id):
        return {"chat": self.view(self._chat(chat_id))}

    def wait(self, chat_id, after, timeout_ms):
        """The chat once its version passes `after`, or as it is at the deadline."""
        deadline = time.monotonic() + min(timeout_ms, 25000) / 1000.0
        while True:
            self.tick()
            r = self._chat(chat_id)
            left = deadline - time.monotonic()
            if r["version"] > after or left <= 0:
                return {"chat": self.view(r)}
            self.cv.wait(min(left, 0.5))

    def keep(self, chat_id, keep):
        r = self._chat(chat_id)
        if not r["auto"]:
            raise Refused(409, "closed", "Auto is off for this chat", chat=self.view(r))
        if r["keep_in_cloud"] != bool(keep):
            r["keep_in_cloud"] = bool(keep)
            self._changed(r)
        return {"chat": self.view(r)}

    def move(self, chat_id, body):
        """A person says where the chat runs from now on: `cloud` or `local`. The holder sees
        the wish at its next renewal, puts all it did in the store's copy, and gives the chat
        on (`give`), in the middle of a turn too: the other side continues it."""
        now = self.clock()
        r = self._chat(chat_id)
        if not r["auto"]:
            raise Refused(409, "closed", "Auto is off for this chat", chat=self.view(r))
        to, holder = body.get("to"), r["holder"]
        if to == "cloud":
            if not self.machine:
                raise Refused(409, "no_machine", "no Cloud machine has asked for work yet")
            if holder == PARKED and not r["snapshot"]:
                raise Refused(409, "no_copy", "the store has no copy of this chat yet")
            r["keep_in_cloud"] = True
            r["move"] = None
            if holder == PARKED:
                self._to_machine(r, "move", now)
            elif is_device(holder):
                r["move"] = "cloud"
        elif to == "local":
            standby = r.get("standby")
            if is_vm(holder) and not (standby and self._fresh(standby, now)):
                raise Refused(409, "no_laptop", "no laptop has this chat open: open it there "
                                                 "with `auto chat %s`" % chat_id)
            r["keep_in_cloud"] = False
            r["move"] = None
            if is_vm(holder):
                r["move"] = "local"
                assignment = r.get("assignment")
                if assignment is None or assignment["acked"]:
                    # Not work: it only wakes the machine's loop for this chat.
                    r["assignment"] = {"kind": "release", "epoch": r["epoch"], "acked": False}
        elif to == "stay":
            r["move"] = None
        else:
            raise Refused(400, "invalid_request", "to must be cloud or local")
        self._changed(r)
        return {"chat": self.view(r)}

    def give(self, chat_id, body):
        """The holder hands the chat on. Refused until the store's copy has every event."""
        now = self.clock()
        r = self._chat(chat_id)
        self._fence(r, body.get("holder"), body.get("epoch"))
        to = body.get("to")
        if not r["snapshot"] or r["snapshot_seq"] != r["last_seq"]:
            raise Refused(409, "not_copied", "the store's copy is behind the chat's events")
        if to == "cloud":
            if not self.machine:
                r["move"] = None
                self._changed(r)
                raise Refused(409, "no_machine", "no Cloud machine has asked for work yet")
            self._to_machine(r, "move", now)
        elif to == "local":
            standby = r.get("standby")
            if not (standby and self._fresh(standby, now)):
                r["move"] = None
                self._changed(r)
                raise Refused(409, "no_laptop", "no laptop has this chat open")
            self._take(r, standby["device"], True, now)
        else:
            raise Refused(400, "invalid_request", "to must be cloud or local")
        self._changed(r)
        return {"chat": self.view(r)}

    # ---- the lease ----

    def lease(self, chat_id, body):
        now = self.clock()
        r = self._chat(chat_id)
        if not r["auto"]:
            raise Refused(409, "closed", "Auto is off for this chat", chat=self.view(r))
        holder, epoch = body.get("holder") or "", body.get("epoch")
        role, bring = "lost", False
        tenure = r.get("tenure", r["epoch"])
        # A holder whose last answer was lost may ask with the epoch before a park and take-back
        # of its own: nobody else held the chat since `tenure`, so it is still the holder.
        mine = isinstance(epoch, int) and holder == r["holder"] and (
            epoch == r["epoch"] or (is_device(holder) and tenure <= epoch <= r["epoch"]))
        if mine:
            needs_run = bool(body.get("needs_run"))
            changed = needs_run != r["needs_run"]
            r["needs_run"] = needs_run
            r["lease_expires"] = now + self.lease_ms
            role, bring = "holder", r["owes_import"]
            if is_vm(holder) and self._can_go_home(r, now):
                self._take(r, r["standby"]["device"], True, now)
                role, bring, changed = "lost", False, True
            if changed:
                self._changed(r)
            else:
                self._save()
        elif is_device(holder):
            if body.get("standby"):
                was = r.get("standby")
                r["standby"] = {"device": holder, "at": now}
                role = "standby"
                if r["holder"] == PARKED and not r["keep_in_cloud"]:
                    self._take(r, holder, r["parked_from"] != holder, now)
                    role, bring = "holder", r["owes_import"]
                    self._changed(r)
                elif holder == r["holder"]:
                    # It was given the chat (a hand-back) and asks as a standby still.
                    r["lease_expires"] = now + self.lease_ms
                    role, bring = "holder", r["owes_import"]
                    self._save()
                elif not was or was["device"] != holder or not self._fresh(was, now):
                    self._changed(r)
                else:
                    self._save()
            elif (r["holder"] == PARKED and r["parked_from"] == holder
                  and isinstance(epoch, int) and tenure <= epoch < r["epoch"]):
                # The laptop whose lease ran out takes the chat back as it is.
                self._take(r, holder, False, now)
                role = "holder"
                self._changed(r)
        return {"role": role, "import": bring, "chat": self.view(r), "timing": self.timing()}

    def _can_go_home(self, r, now):
        standby = r.get("standby")
        assignment = r.get("assignment")
        return (not r["needs_run"] and not self._unread(r)
                and (assignment is None or assignment["acked"])
                and r["snapshot"] and r["snapshot_seq"] == r["last_seq"]
                and standby is not None and self._fresh(standby, now)
                and not r["keep_in_cloud"])

    # ---- the copy ----

    def append_events(self, chat_id, body):
        r = self._chat(chat_id)
        self._fence(r, body.get("holder"), body.get("epoch"))
        events = body.get("events") or []
        added = []
        for event in events:
            seq = event.get("seq")
            if seq <= r["last_seq"]:
                continue
            if seq != r["last_seq"] + 1:
                raise Refused(409, "seq_gap", "events are missing before seq %s" % seq,
                              last_seq=r["last_seq"], chat=self.view(r))
            r["last_seq"] = seq
            added.append(event)
        if added:
            with open(self._events_path(chat_id), "a") as f:
                for event in added:
                    f.write(json.dumps(event) + "\n")
            self._changed(r)
        return {"last_seq": r["last_seq"]}

    def events(self, chat_id, after, wait_ms=0):
        deadline = time.monotonic() + min(wait_ms, 25000) / 1000.0
        while True:
            self.tick()
            r = self._chat(chat_id)
            left = deadline - time.monotonic()
            if r["last_seq"] > after or left <= 0:
                break
            self.cv.wait(min(left, 0.5))
        out = []
        if r["last_seq"] > after:
            try:
                with open(self._events_path(chat_id)) as f:
                    for line in f:
                        event = json.loads(line)
                        if event["seq"] > after:
                            out.append(event)
            except OSError:
                pass
        return {"events": out[:500], "last_seq": r["last_seq"], "chat": self.view(r)}

    def missing_blobs(self, shas):
        return {"missing": [s for s in shas if not os.path.exists(self._blob_path(s))]}

    def put_blob(self, sha, data):
        if hashlib.sha256(data).hexdigest() != sha:
            raise Refused(400, "blob_mismatch", "the bytes do not hash to their name")
        path = self._blob_path(sha)
        if not os.path.exists(path):
            tmp = "%s.%d.tmp" % (path, threading.get_ident())
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, path)
        return {}

    def blob(self, sha):
        try:
            with open(self._blob_path(sha), "rb") as f:
                return f.read()
        except OSError:
            raise Refused(404, "not_found", "no such blob")

    def post_snapshot(self, chat_id, body):
        r = self._chat(chat_id)
        self._fence(r, body.get("holder"), body.get("epoch"))
        manifest = body.get("manifest") or {}
        shas = [entry[0] for entry in (manifest.get("files") or {}).values()]
        session = manifest.get("session") or {}
        if session.get("sha"):
            shas.append(session["sha"])
        missing = self.missing_blobs(shas)["missing"]
        if missing:
            raise Refused(409, "snapshot_incomplete", "blobs are missing", missing=missing)
        r["snapshot"] += 1
        r["snapshot_seq"] = min(int(manifest.get("seq") or 0), r["last_seq"])
        r["manifest"] = manifest
        r["owes_import"] = False
        if manifest.get("cwd") and is_device(r["holder"]):
            r["cwd"] = manifest["cwd"]
        self._changed(r)
        return {"snapshot": r["snapshot"], "snapshot_seq": r["snapshot_seq"]}

    def snapshot(self, chat_id):
        r = self._chat(chat_id)
        if not r["snapshot"]:
            raise Refused(404, "no_snapshot", "the store has no copy of this chat")
        return {"snapshot": r["snapshot"], "snapshot_seq": r["snapshot_seq"],
                "manifest": r["manifest"]}

    # ---- the inbox ----

    def post_inbox(self, chat_id, body):
        now = self.clock()
        r = self._chat(chat_id)
        if not r["auto"]:
            raise Refused(409, "closed", "Auto is off for this chat", chat=self.view(r))
        if not body.get("id") or not body.get("text"):
            raise Refused(400, "invalid_request", "a message needs id and text")
        for message in r["inbox"]:
            if message["id"] == body["id"]:
                return {"state": message.get("state", "delivered"), "chat": self.view(r)}
        message = {"n": len(r["inbox"]) + 1, "id": body["id"], "text": body["text"],
                   "at": now, "from": body.get("from") or "device"}
        r["inbox"].append(message)
        holder = r["holder"]
        if is_device(holder):
            state = "delivered"
        elif is_vm(holder):
            assignment = r.get("assignment")
            if assignment is None or assignment["acked"]:
                r["assignment"] = {"kind": "deliver", "epoch": r["epoch"], "acked": False}
                self._wake(now)
            state = "delivered" if assignment and assignment["acked"] else "resuming"
        elif r["snapshot"] and self.machine:
            self._to_machine(r, "deliver", now)
            state = "resuming"
        else:
            state = "queued"
        message["state"] = state
        self._changed(r)
        return {"state": state, "chat": self.view(r)}

    def inbox(self, chat_id, after):
        r = self._chat(chat_id)
        return {"messages": [m for m in r["inbox"] if m["n"] > after]}

    def ack_inbox(self, chat_id, body):
        r = self._chat(chat_id)
        self._fence(r, body.get("holder"), body.get("epoch"))
        n = min(int(body.get("n") or 0), len(r["inbox"]))
        if n > r["inbox_acked"]:
            r["inbox_acked"] = n
            self._changed(r)
        return {"chat": self.view(r)}

    # ---- the machine ----

    def assignments(self, machine, wait_ms):
        """What the Auto machine has to do. The first machine to ask is the Auto machine."""
        deadline = time.monotonic() + min(wait_ms, 25000) / 1000.0
        while True:
            now = self.clock()
            if self.machine is None or self.machine["name"] != machine:
                if self.machine is None or now - self.machine["seen_at"] > 60000:
                    self.machine = {"name": machine, "seen_at": now}
                    self._save()
                    self.cv.notify_all()
                else:
                    raise Refused(409, "other_machine",
                                  "the Auto machine is %s" % self.machine["name"])
            self.machine["seen_at"] = now
            self.tick()
            holder = "vm:" + machine
            out = []
            for r in self.chats.values():
                assignment = r.get("assignment")
                if r["auto"] and r["holder"] == holder and assignment and not assignment["acked"]:
                    out.append({"chat": r["id"], "kind": assignment["kind"], "epoch": r["epoch"],
                                "title": r["title"]})
            left = deadline - time.monotonic()
            if out or left <= 0:
                return {"assignments": out, "timing": self.timing()}
            self.cv.wait(min(left, 0.5))

    def ack_assignment(self, chat_id, body):
        now = self.clock()
        r = self._chat(chat_id)
        self._fence(r, body.get("holder"), body.get("epoch"))
        assignment = r.get("assignment")
        if assignment and not assignment["acked"]:
            assignment["acked"] = True
            r["lease_expires"] = now + self.lease_ms
            self._changed(r)
        return {"chat": self.view(r)}
