#!/usr/bin/env python3
"""Live check of Delete Group and Ungroup from the GUI (#22996) on a tagged app.

Run it on cmux-lawrence-2 in an nx-remote GUI job with a fleet-built app:

  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA \
    -- python3 scripts/cmux-next/sidebar-group-delete-live.py --out "$NX_ARTIFACTS"

Each step makes a throwaway group, then runs the group header menu's action
(`workspaceGroup.delete`, `workspaceGroup.ungroup`, `workspaceGroup.rename`)
with the person's origin and the target the header menu sends: the group id
the sidebar row shows (`debug.sidebar_rows`). It prints the ids each layer
knows the group by (the row, the sidebar document, the personal store), the
refusal HUD and whether the group left the sidebar and the document while its
workspaces stayed. Groups: one made by the CLI (a personal group the document
syncs as `itm_g_<id>`) and one made by the app's New Group action. Exit 1 when
any step FAILs.
"""
import argparse, json, os, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
opts = parser.parse_args()
APP = os.environ.get("NX_APP")
TAG = os.environ.get("NX_APP_TAG", "")
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.environ.get("NX_APP_CLI") or (APP and os.path.join(APP, "Contents/Resources/bin/cmux"))
STOP = os.environ.get("NX_APP_STOP")
if not APP or not STOP:
    sys.exit("run inside `nx-remote --needs gui --app-from-fleet cmux` (NX_APP, NX_APP_STOP)")
SCRATCH = tempfile.mkdtemp(prefix=f"group-delete-{TAG}-")
CONFIG, GHOSTTY = os.path.join(SCRATCH, "cmux.json"), os.path.join(SCRATCH, "ghostty")
open(GHOSTTY, "w").write("")
open(CONFIG, "w").write("{}")
os.makedirs(opts.out, exist_ok=True)
RESULTS = []
# Names of this run, so a rerun on the same tag (its workspaces stay) finds its own rows.
RUN = os.urandom(2).hex()
ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "CMUX_QUIET": "1"}


def rpc(method, params=None):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def cli(*args):
    out = subprocess.run([CLI, "--app-socket", SOCKET, *args], capture_output=True, text=True, timeout=30, env=ENV)
    return (out.stdout + out.stderr).strip()


def doc_groups(section=None):
    """The group items of the home daemon's sidebar document (sidebar.get): id -> name (in `section` only, if given)."""
    tui = os.path.join(os.path.dirname(CLI), "cmux-tui")
    params = '{"machine":"current","session":"current"}'
    out = subprocess.run([tui, "--app-socket", SOCKET, "--json", "raw", "operation", "sidebar.get", "--params-json", params],
                         capture_output=True, text=True, timeout=30, env=ENV)
    try:
        doc = json.loads(out.stdout)
    except ValueError:
        return {"error": (out.stdout + out.stderr)[:300]}
    found = {}

    def walk(value):
        if isinstance(value, dict):
            body = value.get("body")
            if isinstance(body, dict) and body.get("type") == "group" and value.get("id") and section in (None, value.get("section")):
                found[value["id"]] = body.get("name")
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
    walk(doc)
    return found


def doc_pinned_groups():
    return doc_groups("sec_pinned")


def wait(predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)  # test harness wait, not app code
    return None


def report():
    value = rpc("debug.sidebar_rows") or {}
    return value if isinstance(value, dict) else {}


def window():
    return (report().get("windows") or [{}])[0]


def rows():
    return window().get("rows", [])


def by_title(title):
    return next((r for r in rows() if r.get("title") == title), None)


def row_id(row):
    key = str((row or {}).get("key", ""))
    return key[key.find("(") + 1:key.rfind(")")] if "(" in key else key


def group_rows():
    return [r for r in rows() if str(r.get("key", "")).startswith("group")]


def refusals():
    return (rpc("debug.toast") or {}).get("refusals") or []


def perform(action, group, **arguments):
    return rpc("debug.toast", {"perform": action, "target_kind": "workspace-group", "target_id": group, "arguments": arguments})


def shot(name):
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, name + ".png")})


def record(step, ok, evidence):
    state = "PASS" if ok else "FAIL"
    RESULTS.append((step, state))
    print(f"{state} {step}: {evidence}", flush=True)


def launch():
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = ["CMUX_NEXT_NO_ACTIVATE=1", "CMUX_NEXT_SOCKET_MODE=automation", "CMUX_NEXT_TEST_WINDOW_SCREEN=last",
           f"CMUX_NEXT_CONFIG_FILE={CONFIG}", f"CMUX_NEXT_GHOSTTY_CONFIG={GHOSTTY}", "CMUX_NEXT_TEST_WINDOW_FRAME=40,40,1100,720"]
    # In the background (`-g`, CMUX_NEXT_NO_ACTIVATE): the job never takes the focus.
    subprocess.run(["open", "-g", "-n", APP, *[arg for pair in env for arg in ("--env", pair)]], check=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 120):
        sys.exit("FAIL the tagged app did not come up")
    wait(lambda: (report().get("doc") or {}).get("active"), 30)
    time.sleep(1.5)  # test harness: let the window settle


def describe(label):
    print(f"{label}: rows={[(r.get('key'), r.get('group'), r.get('title')) for r in rows()]}", flush=True)
    print(f"{label}: doc groups={doc_groups()}", flush=True)
    print(f"{label}: personal groups={cli('workspace', 'group', 'list')[:600]}", flush=True)


def new_group_header(known):
    """The header row of a group that is not in `known`."""
    return wait(lambda: next((r for r in group_rows() if r.get("group") not in known), None), 10)


def check_removed(label, member, action, verb):
    """Runs `action` on the newest group (the one holding `member`) as the header menu does and checks it went."""
    member_row = wait(lambda: (by_title(member) or {}).get("group") and by_title(member), 10)
    if not member_row:
        describe(label)
        return record(f"{label}: the throwaway group shows", False, f"no grouped row for {member}")
    group = member_row["group"]
    describe(f"{label} before")
    before = len(refusals())
    reply = perform(action, group)
    gone = wait(lambda: not any(r.get("group") == group for r in rows()) or None, 8)
    time.sleep(1.0)  # test harness: a late refusal from the daemon shows after its reply
    new_refusals = refusals()[before:]
    shot(f"{label}-after")
    describe(f"{label} after")
    stays = by_title(member)
    record(f"{label}: {verb} from the header menu", bool(gone) and not new_refusals and bool(stays) and not stays.get("group"),
           f"group={group} performed={reply.get('performed')} gone={bool(gone)} refusals={new_refusals} "
           f"member={stays and (stays.get('title'), stays.get('group'))} doc={doc_groups()}")


launch()
print("doc:", json.dumps(report().get("doc") or {})[:600], flush=True)
try:
    for name in (f"Alpha-{RUN}", f"Bravo-{RUN}", f"Charlie-{RUN}", f"Delta-{RUN}"):
        cli("workspace", "create", "--name", name)
    wait(lambda: by_title(f"Alpha-{RUN}") and by_title(f"Delta-{RUN}"), 20)
    shot("0-start")

    # 1. A CLI-made group (personal store first), deleted from the header menu.
    print(cli("workspace", "group", "create", "--name", f"Throwaway CLI {RUN}"), flush=True)
    print(cli("workspace", "group", f"Throwaway CLI {RUN}", "add", "--workspace", f"Alpha-{RUN}"), flush=True)
    check_removed("1-cli-group-delete", f"Alpha-{RUN}", "workspaceGroup.delete", "Delete Group")

    # 2. A CLI-made group, ungrouped from the header menu.
    print(cli("workspace", "group", "create", "--name", f"Throwaway Ungroup {RUN}"), flush=True)
    print(cli("workspace", "group", f"Throwaway Ungroup {RUN}", "add", "--workspace", f"Bravo-{RUN}"), flush=True)
    check_removed("2-cli-group-ungroup", f"Bravo-{RUN}", "workspaceGroup.ungroup", "Ungroup")

    # 3. A group made by the app (New Group from the workspace menu), renamed and then deleted from the header menu.
    known = {r.get("group") for r in group_rows()}
    print("new group:", rpc("debug.toast", {"perform": "newWorkspaceGroup", "target_kind": "workspace",
                                            "target_id": row_id(by_title(f"Charlie-{RUN}")), "arguments": {"name": f"Throwaway App {RUN}"}}), flush=True)
    header = new_group_header(known)
    if header:
        before = len(refusals())
        perform("workspaceGroup.rename", header["group"], name=f"Throwaway Renamed {RUN}")
        renamed = wait(lambda: f"Throwaway Renamed {RUN}" in doc_groups().values() or None, 8)
        record("3-app-group-rename: Rename from the header menu", bool(renamed) and not refusals()[before:],
               f"group={header['group']} refusals={refusals()[before:]} doc={doc_groups()}")
    check_removed("3-app-group-delete", f"Charlie-{RUN}", "workspaceGroup.delete", "Delete Group")

    # 4-6. A pinned group (Pinned lists it as a header and member rows): rename, ungroup and delete it there.
    for step, member, action, verb in (("4-pinned-group-ungroup", f"Delta-{RUN}", "workspaceGroup.ungroup", "Ungroup"),
                                       ("5-pinned-group-delete", f"Alpha-{RUN}", "workspaceGroup.delete", "Delete Group")):
        name = f"Throwaway Pinned {step[0]} {RUN}"
        print(cli("workspace", "group", "create", "--name", name), flush=True)
        print(cli("workspace", "group", name, "add", "--workspace", member), flush=True)
        grouped = wait(lambda: (by_title(member) or {}).get("group") and by_title(member), 10)
        if not grouped:
            record(f"{step}: the throwaway group shows", False, f"no grouped row for {member}")
            continue
        before = len(refusals())
        perform("workspaceGroup.togglePin", grouped["group"])
        pinned = wait(lambda: any(i == grouped["group"] or i.endswith(grouped["group"]) for i, n in doc_pinned_groups().items()) or None, 8)
        record(f"{step}: Pin Group", bool(pinned) and not refusals()[before:], f"refusals={refusals()[before:]} pinned={doc_pinned_groups()}")
        shown = wait(lambda: (by_title(member) or {}).get("group") and by_title(member), 10)
        print(f"{step} pinned row group id: {(shown or {}).get('group')}", flush=True)
        if action == "workspaceGroup.ungroup":
            before = len(refusals())
            perform("workspaceGroup.rename", (shown or grouped)["group"], name=name + " renamed")
            renamed = wait(lambda: name + " renamed" in doc_groups().values() or None, 8)
            record(f"{step}: Rename a pinned group", bool(renamed) and not refusals()[before:],
                   f"refusals={refusals()[before:]} doc={doc_groups()}")
        check_removed(step, member, action, verb)
except Exception as error:  # report, then stop the app
    record("harness", False, repr(error))
finally:
    subprocess.run([STOP])

print("RESULTS:", json.dumps(RESULTS), flush=True)
sys.exit(1 if any(state == "FAIL" for _, state in RESULTS) else 0)
