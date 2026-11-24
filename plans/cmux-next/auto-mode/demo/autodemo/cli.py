"""The `auto` command.

  auto cloud                     on the Cloud machine: the store and the machine side, together
  auto serve / auto machine      the two halves on their own
  auto login URL TOKEN           point this device at a store
  auto chat [ID] [-m TEXT]       on the laptop: a chat with Auto on, in this folder
  auto attach ID                 from any device: follow a chat and send to it
  auto new TEXT                  from any device: start a chat in the Cloud
  auto send ID TEXT              one message, no view
  auto ls / auto status          what the store has
  auto keep ID on|off            whether a chat stays in the Cloud when the laptop is back
  auto off ID                    Auto off for a chat
"""

import argparse
import json
import os
import secrets
import socket
import sys
import threading
import time
import uuid

from . import ui as ui_mod
from .client import Client, Offline, Refused
from .holder import Chat, where


def home():
    return os.environ.get("AUTO_HOME") or os.path.join(os.path.expanduser("~"), ".cmux-auto-demo")


def load_config():
    try:
        with open(os.path.join(home(), "config.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_config(config):
    os.makedirs(home(), exist_ok=True)
    path = os.path.join(home(), "config.json")
    with open(path, "w") as f:
        json.dump(config, f, indent=1)
    os.chmod(path, 0o600)


def client():
    config = load_config()
    url = os.environ.get("AUTO_STORE_URL") or config.get("url")
    token = os.environ.get("AUTO_STORE_TOKEN") or config.get("token") or ""
    if not url:
        sys.exit("no store: run `auto login URL TOKEN` (or set AUTO_STORE_URL and AUTO_STORE_TOKEN)")
    return Client(url, token, headers=config.get("headers"))


def device():
    """This device's name as a holder, made once."""
    config = load_config()
    if not config.get("device"):
        name = socket.gethostname().split(".")[0].lower()
        name = "".join(ch if ch.isalnum() or ch == "-" else "-" for ch in name)[:24]
        config["device"] = "device:%s-%s" % (name, secrets.token_hex(2))
        save_config(config)
    return os.environ.get("AUTO_DEVICE") or config["device"]


# ---- the Cloud side ----

def cmd_serve(args):
    from .server import serve
    server, _store = serve(args.data or os.path.join(home(), "store"), args.host, args.port,
                           args.token, int(args.lease * 1000), args.wake_cmd)
    print("store on http://%s:%d (lease %ss)" % (args.host, args.port, args.lease), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


class MachineUI(ui_mod.PlainUI):
    """A machine's log: one line per event, named by chat."""

    def __init__(self, chat_id):
        ui_mod.PlainUI.__init__(self)
        self.chat_id = chat_id

    def line(self, text=""):
        if text.strip():
            ui_mod.PlainUI.line(self, "%s %s | %s" % (time.strftime("%H:%M:%S"), self.chat_id, text))

    def delta(self, text):
        pass

    def end_delta(self):
        pass

    def status(self, text):
        pass


def run_machine(c, name, work, model=None, stop=None):
    """The Auto machine: asks the store for work, and does it."""
    me = "vm:" + name
    chats = {}
    root = home()
    os.makedirs(os.path.join(root, "chats"), exist_ok=True)

    def chat_for(chat_id):
        if chat_id not in chats:
            chat = Chat(c, me, chat_id, os.path.join(work, chat_id), root, MachineUI(chat_id), model=model)
            chats[chat_id] = chat
        return chats[chat_id]

    # The chats this machine held when it last ran: each asks the store before anything runs.
    for chat_id in sorted(os.listdir(os.path.join(root, "chats"))):
        chat = chat_for(chat_id)
        if chat.mode == "holding":
            chat.start()
        else:
            chat.mode = "away"
    print("%s machine %s asking %s for work" % (time.strftime("%H:%M:%S"), name, c.url), flush=True)
    while not (stop and stop.is_set()):
        try:
            answer = c.assignments(name, wait_ms=15000)
        except Offline:
            time.sleep(2)
            continue
        except Refused as refused:
            print("the store refused this machine: %s" % refused, flush=True)
            time.sleep(5)
            continue
        for assignment in answer["assignments"]:
            chat = chat_for(assignment["chat"])
            try:
                if chat.mode == "holding" and chat.epoch == assignment["epoch"]:
                    chat.deliver(assignment)
                else:
                    print("%s %s | %s (epoch %d)" % (time.strftime("%H:%M:%S"), chat.id,
                                                      assignment["kind"], assignment["epoch"]), flush=True)
                    chat.take(assignment)
                    if not chat.threads:
                        chat.start()
            except (Offline, Refused) as error:
                print("%s %s | could not start: %s" % (time.strftime("%H:%M:%S"), chat.id, error), flush=True)
                time.sleep(1)
    for chat in chats.values():
        chat.close(final_copy=False)


def cmd_machine(args):
    try:
        run_machine(client(), args.name, os.path.realpath(args.work), args.model)
    except KeyboardInterrupt:
        pass


def cmd_cloud(args):
    """The store and the machine side in one process, for one Cloud machine."""
    from .server import serve
    token = args.token or load_config().get("token") or secrets.token_urlsafe(18)
    config = load_config()
    config.update({"url": "http://127.0.0.1:%d" % args.port, "token": token})
    save_config(config)
    server, _store = serve(args.data or os.path.join(home(), "store"), args.host, args.port,
                           token, int(args.lease * 1000), args.wake_cmd)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print("store on port %d (lease %ss); other devices: auto login http://<this machine>:%d <token in %s>"
          % (args.port, args.lease, args.port, os.path.join(home(), "config.json")), flush=True)
    try:
        run_machine(Client(config["url"], token), args.name, os.path.realpath(args.work), args.model)
    except KeyboardInterrupt:
        pass


def cmd_relay(args):
    from . import relay
    token = args.token or os.environ.get("AUTO_RELAY_TOKEN") or load_config().get("token")
    if not token:
        sys.exit("give --token (the same on both sides)")
    try:
        if args.side == "in":
            relay.serve_in(args.port, args.tunnel_port, token)
        else:
            if not args.target:
                sys.exit("auto relay out HOST:PORT")
            relay.serve_out(args.target, token)
    except KeyboardInterrupt:
        pass


# ---- any device ----

def cmd_login(args):
    config = load_config()
    config.update({"url": args.url.rstrip("/"), "token": args.token})
    if args.header:
        config["headers"] = dict(h.split("=", 1) for h in args.header)
    save_config(config)
    try:
        status = client().status()
    except (Offline, Refused) as error:
        sys.exit("saved, but the store did not answer: %s" % error)
    machine = status["machine"]
    print("ok: store reached; Auto machine: %s" % (
        "%s (%s)" % (machine["name"], "awake" if machine["awake"] else "asleep") if machine else "none yet"))


def age(ms):
    s = max(0, ms) // 1000
    return "%ds" % s if s < 90 else "%dm" % (s // 60) if s < 5400 else "%dh" % (s // 3600)


def row(view, now):
    state = {"local": "on " + ui_mod.who(view["holder"]), "cloud": "in the Cloud (%s)" % view["holder"][3:],
             "resuming": "resuming in the Cloud", "parked": "parked", "off": "Auto off"}[view["state"]]
    if view["state"] == "local" and view["needs_run"]:
        state += ", working"
    if view["state"] == "cloud":
        state += ", working" if view["needs_run"] else ", idle"
    if view.get("blocked"):
        state += " [%s]" % view["blocked"]
    return "%-12s %-34s %-40s epoch %-3d copy #%-3d %s ago" % (
        view["id"], view["title"][:34], state, view["epoch"], view["snapshot"], age(now - view["updated_at"]))


def cmd_ls(args):
    c = client()
    status = c.status()
    for view in c.chats():
        print(row(view, status["now"]))


def cmd_status(args):
    c = client()
    while True:
        status = c.status()
        machine = status["machine"]
        lines = ["store %s   lease %ds   Auto machine: %s   wakes: %d" % (
            c.url, status["timing"]["lease_ms"] // 1000,
            "%s (%s)" % (machine["name"], "awake" if machine["awake"] else "asleep %s" % age(machine["seen_ms_ago"]))
            if machine else "none", status["wakes"]), ""]
        lines += [row(view, status["now"]) for view in c.chats()]
        if not args.watch:
            print("\n".join(lines))
            return
        sys.stdout.write("\x1b[H\x1b[2J" + "\n".join(lines) + "\n")
        sys.stdout.flush()
        time.sleep(1)


def cmd_send(args):
    answer = client().post_inbox(args.id, "m-" + uuid.uuid4().hex[:12], args.text, device())
    print("%s (%s)" % (answer["state"], where(answer["chat"])))


def cmd_keep(args):
    view = client().keep(args.id, args.value == "on")
    print("keep in Cloud: %s" % ("on" if view["keep_in_cloud"] else "off"))


def cmd_off(args):
    try:
        client().put(args.id, {"auto": False})
        print("Auto is off for %s" % args.id)
    except Refused as refused:
        sys.exit(str(refused))


def follow(c, chat_id, ui, sender, stop):
    """Shows a chat's events as the store gets them, and says where it runs."""
    seq, shown = 0, None
    while not stop.is_set():
        try:
            answer = c.events(chat_id, seq, wait_ms=10000)
        except Offline:
            ui.status("no answer from the Cloud")
            time.sleep(1)
            continue
        except Refused as refused:
            ui.note(str(refused))
            return
        for event in answer["events"]:
            ui.event(event)
            seq = event["seq"]
        view = answer["chat"]
        line = "%s  |  %s%s" % (view["title"][:30], where(view),
                               {"resuming": " (resuming...)", "cloud": ", working" if view["needs_run"] else ", idle",
                                "local": ", working" if view["needs_run"] else ", idle"}.get(view["state"], ""))
        if line != shown:
            shown = line
            ui.status(line)


def cmd_attach(args, c=None, chat_id=None):
    c = c or client()
    chat_id = chat_id or args.id
    try:
        c.chat(chat_id)
    except Refused as refused:
        sys.exit(str(refused))
    ui = ui_mod.make()
    stop = threading.Event()
    me = device()
    threading.Thread(target=follow, args=(c, chat_id, ui, me, stop), daemon=True).start()
    try:
        while True:
            line = ui.read_line()
            if line is None or line.strip() in ("/quit", "/q"):
                break
            if not line.strip():
                continue
            try:
                answer = c.post_inbox(chat_id, "m-" + uuid.uuid4().hex[:12], line.strip(), me)
                if answer["state"] != "delivered":
                    ui.note({"resuming": "sent: the Cloud machine is starting", "queued": "sent: it waits for the laptop"}[answer["state"]])
            except (Offline, Refused) as error:
                ui.note("not sent: %s" % error)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        ui.close()


def cmd_new(args):
    c = client()
    try:
        view = c.create({"title": args.title, "from": device(),
                         "message": {"id": "m-" + uuid.uuid4().hex[:12], "text": args.text}})
    except Refused as refused:
        sys.exit(str(refused))
    print("chat %s: %s" % (view["id"], where(view)))
    if not args.detach:
        cmd_attach(args, c, view["id"])


# ---- the laptop ----

HELP = "/away  act out no network    /back  network again    /keep on|off    /off  Auto off    /quit"


def cmd_chat(args):
    c = client()
    me = device()
    chat_id = args.id or "c" + uuid.uuid4().hex[:8]
    folder = os.path.realpath(args.dir or os.getcwd())
    ui = ui_mod.make()
    chat = Chat(c, me, chat_id, folder, home(), ui, model=args.model,
                title=args.title or (args.message or os.path.basename(folder))[:48])
    ui.note("chat %s in %s  (%s)" % (chat_id, chat.folder, HELP))
    for event in chat.events:
        ui.event(event)
    chat.start()
    if args.message:
        chat.submit(args.message)
    try:
        while True:
            line = ui.read_line()
            if line is None:
                break
            text = line.strip()
            if not text:
                continue
            if text in ("/quit", "/q"):
                break
            if text == "/away":
                c.cut = True
                ui.note("acting out a laptop with no network")
            elif text == "/back":
                c.cut = False
                chat.wake.set()
                ui.note("the network is back")
            elif text.startswith("/keep"):
                try:
                    view = chat.set_keep(text.split()[-1] != "off")
                    ui.note("keep in Cloud: %s" % ("on" if view["keep_in_cloud"] else "off"))
                except (Offline, Refused) as error:
                    ui.note(str(error))
            elif text == "/off":
                try:
                    chat.turn_off()
                    ui.note("Auto is off: the chat runs only here")
                except (Offline, Refused) as error:
                    ui.note(str(error))
            elif text == "/status":
                ui.note(chat.status_line())
            elif text.startswith("/"):
                ui.note(HELP)
            else:
                said = chat.submit(text)
                if said == "sent":
                    ui.note("sent to the chat's holder")
    except KeyboardInterrupt:
        pass
    finally:
        chat.close()
        ui.close()
        print("left chat %s; open it again with: auto chat %s" % (chat_id, chat_id))


def main(argv=None):
    parser = argparse.ArgumentParser(prog="auto", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd")

    def cloud_args(p):
        p.add_argument("--host", default="0.0.0.0")
        p.add_argument("--port", type=int, default=7717)
        p.add_argument("--token", default=os.environ.get("AUTO_STORE_TOKEN"))
        p.add_argument("--lease", type=float, default=15.0, help="seconds a laptop's lease lasts (the product: 45)")
        p.add_argument("--data", help="where the store keeps its state")
        p.add_argument("--wake-cmd", help="run when the Auto machine has work and has not asked lately")

    def machine_args(p):
        p.add_argument("--name", default=socket.gethostname().split(".")[0])
        p.add_argument("--work", default=os.path.join(os.path.expanduser("~"), "auto-demo-chats"))
        p.add_argument("--model")

    p = sub.add_parser("serve"); cloud_args(p); p.set_defaults(fn=cmd_serve)
    p = sub.add_parser("machine"); machine_args(p); p.set_defaults(fn=cmd_machine)
    p = sub.add_parser("cloud"); cloud_args(p); machine_args(p); p.set_defaults(fn=cmd_cloud)
    p = sub.add_parser("relay", help="a model route for a machine that has none")
    p.add_argument("side", choices=["in", "out"]); p.add_argument("target", nargs="?")
    p.add_argument("--port", type=int, default=7790); p.add_argument("--tunnel-port", type=int, default=7791)
    p.add_argument("--token"); p.set_defaults(fn=cmd_relay)
    p = sub.add_parser("login"); p.add_argument("url"); p.add_argument("token")
    p.add_argument("--header", action="append", help="NAME=VALUE sent with every call"); p.set_defaults(fn=cmd_login)
    p = sub.add_parser("chat"); p.add_argument("id", nargs="?"); p.add_argument("-C", "--dir")
    p.add_argument("-m", "--message"); p.add_argument("--model"); p.add_argument("--title"); p.set_defaults(fn=cmd_chat)
    p = sub.add_parser("attach"); p.add_argument("id"); p.set_defaults(fn=cmd_attach)
    p = sub.add_parser("new"); p.add_argument("text"); p.add_argument("--title"); p.add_argument("--detach", action="store_true"); p.set_defaults(fn=cmd_new)
    p = sub.add_parser("send"); p.add_argument("id"); p.add_argument("text"); p.set_defaults(fn=cmd_send)
    p = sub.add_parser("ls"); p.set_defaults(fn=cmd_ls)
    p = sub.add_parser("status"); p.add_argument("--watch", "-w", action="store_true"); p.set_defaults(fn=cmd_status)
    p = sub.add_parser("keep"); p.add_argument("id"); p.add_argument("value", choices=["on", "off"]); p.set_defaults(fn=cmd_keep)
    p = sub.add_parser("off"); p.add_argument("id"); p.set_defaults(fn=cmd_off)
    args = parser.parse_args(argv)
    if os.environ.get("AUTO_DEBUG"):
        # kill -USR1 <pid> prints every thread's stack.
        import faulthandler
        import signal
        faulthandler.register(signal.SIGUSR1, all_threads=True)
    if not args.cmd:
        parser.print_help()
        return 0
    try:
        return args.fn(args) or 0
    except Offline as error:
        sys.exit("the store did not answer: %s" % error)
