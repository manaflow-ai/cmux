"""The production Mac -> phone journey, step by step, against the real rig.

Every step drives the phone with real HID touches (AXe) and the software
keyboard, checks the effect on the Mac through the tagged app's own CLI, and
records pass / fail / blocked with timings, notes and a screenshot.
"""
import json
import os
import random
import re
import subprocess
import time
import traceback

BUNDLE = "dev.cmux.cnx"


class Blocked(Exception):
    """The step cannot run in this rig (missing prerequisite); never a pass."""


class Fail(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Fail(msg)


class Journey:
    def __init__(self, sim, mac, out_dir, app_path, log):
        self.sim, self.mac, self.out, self.app_path, self.log = sim, mac, out_dir, app_path, log
        self.results = []
        self.run_id = time.strftime("%H%M%S")
        self.ws_name = f"e2e-{self.run_id}"
        self.seed = {}
        self.device_id = None
        self.ws_row_label = None
        self.grid_notes = []
        self.hangs = []

    # ------------------------------------------------------------------ runner
    def app_pid(self):
        r = subprocess.run(["pgrep", "-f", f"{self.sim.udid}/data/Containers/Bundle/Application/.*/CnxApp.app/CnxApp"],
                           capture_output=True, text=True)
        pids = r.stdout.split()
        return int(pids[0]) if pids else None

    def check_hang(self, where):
        """An empty AX tree with the app pegged at ~100% CPU is a main-thread hang: sample it,
        record it, relaunch. Returns the record or None."""
        if len(self.sim.tree()) > 1:
            return None
        pid = self.app_pid()
        if not pid:
            hang = {"where": where, "kind": "not running"}
        else:
            cpu = float(subprocess.run(["ps", "-o", "%cpu=", "-p", str(pid)], capture_output=True, text=True).stdout.strip() or 0)
            time.sleep(3)
            if len(self.sim.tree()) > 1:
                return None
            path = os.path.join(self.out, f"hang-{len(self.hangs)+1}-{where}.sample.txt")
            subprocess.run(["sample", str(pid), "3", "-file", path], capture_output=True)
            hang = {"where": where, "kind": "main thread busy, no accessibility", "cpu": cpu, "sample": os.path.basename(path)}
            self.sim.shot(f"hang-{len(self.hangs)+1}-{where}")
        self.hangs.append(hang)
        self.log(f"    HANG after {where}: {hang}; relaunching the app")
        self.sim.launch(BUNDLE)
        time.sleep(4)
        return hang

    def step(self, sid, title, owner, fn):
        self.check_hang(f"before-{sid}")
        self.log(f"--- {sid}: {title}")
        t0 = time.time()
        rec = {"id": sid, "title": title, "owner": owner, "started": t0}
        try:
            notes = fn() or {}
            rec.update(status="pass", **({"notes": notes} if isinstance(notes, str) else notes))
        except Blocked as e:
            rec.update(status="blocked", notes=str(e))
        except Exception as e:  # any error is this step's failure; the journey goes on
            rec.update(status="fail", notes=str(e)[:600], trace=traceback.format_exc(limit=3)[-800:])
        rec["seconds"] = round(time.time() - t0, 2)
        rec["screenshot"] = self.sim.shot(f"{len(self.results)+1:02d}-{sid}")
        hang = self.check_hang(sid)
        if hang:
            rec["hang"] = hang
            if rec["status"] == "pass":
                rec["status"] = "fail"
            rec["notes"] = f"APP HUNG ({hang['kind']}, sample {hang.get('sample')}). " + str(rec.get("notes", ""))
        self.results.append(rec)
        self.log(f"    {rec['status'].upper()} ({rec['seconds']} s) {rec.get('notes', '')}")
        return rec["status"] == "pass"

    # ------------------------------------------------------------------ helpers
    def tab(self, name):
        """Selects a tab bar item; a scrolled page minimizes the iOS 26 tab bar, so scroll up first."""
        self.sim.close_drawer()
        for _ in range(4):
            e = self.sim.find(label=name, kind="RadioButton")
            if e:
                self.sim.tap_el(e[0]); time.sleep(0.8)
                return
            self.sim.drag(201, 250, 201, 750, 0.3, 20, 0.1); time.sleep(0.8)
        raise Fail(f"tab bar item {name!r} not found")

    def mac_screen(self, term):
        return self.mac.cmux("terminal", term, "screen", "read", json_out=True)

    def mac_wait_text(self, term, needle, timeout=15.0, count=1):
        deadline = time.time() + timeout
        text = ""
        while time.time() < deadline:
            text = self.mac_screen(term).get("text", "")
            if text.count(needle) >= count:
                return text
            time.sleep(0.25)
        raise Fail(f"Mac terminal never showed {needle!r} x{count}; last screen tail: {text[-200:]!r}")

    def mac_write(self, term, text):
        self.mac.cmux("terminal", term, "write", "--text", text)

    SYSTEM_DISMISS = ("Not Now", "Don’t Allow", "Don't Allow", "Cancel")

    def dismiss_system(self, els=None):
        els = els if els is not None else self.sim.tree()
        for label in self.SYSTEM_DISMISS:
            hit = [e for e in els if e.label == label and e.kind == "Button"]
            if hit and any(k in (x.label or "") for x in els for k in ("Dictation", "Allow", "Notifications", "would like")):
                self.sim.press(*hit[0].center); time.sleep(0.8)
                return True
        return False

    def back_to_list(self):
        """From anywhere: dismiss alerts, close the drawer and keyboard, pop to the Workspaces list."""
        tapped_back = kb_tries = sheet_try = 0
        for _ in range(16):
            els = self.sim.tree()
            if self.dismiss_system(els):
                continue
            if any(e.label == "Close teams" for e in els):
                self.sim.drag(380, 500, 60, 500, 0.4, 20, 0.1); time.sleep(0.8); continue
            if any(e.ident == "workspaces.list" for e in els) and any(e.label == "Workspaces" and e.kind == "RadioButton" for e in els):
                return
            grab = [e for e in els if e.label == "Sheet Grabber"]
            if grab:  # a sheet: its Done (or back inside it), else drag the grabber down
                gy = grab[0].frame[1]
                inner = [e for e in els if e.kind == "Button" and gy < e.frame[1] < gy + 80
                         and (e.label in ("Done", "Close", "Cancel") or e.ident == "BackButton")]
                done = [e for e in inner if e.label in ("Done", "Close", "Cancel")]
                if done or inner:
                    self.sim.tap_el((done or inner)[0]); time.sleep(1.0); continue
                self.sim.drag(201, gy + 10, 201, 870, 0.3, 20, 0.1); time.sleep(1.0); continue
            grid_done = [e for e in els if e.kind == "Button" and e.label == "Done" and e.frame[1] > 700]
            if grid_done:  # the tab grid
                self.sim.tap_el(grid_done[0]); time.sleep(1.0); continue
            if self.sim.keyboard(els) and kb_tries < 2:
                kb_tries += 1
                cancel = [e for e in els if e.kind == "Button" and e.label == "Cancel" and e.frame[0] >= 0]
                if cancel:  # a browser address field holds the keyboard
                    self.sim.tap_el(cancel[0]); time.sleep(1.0); continue
                self.hide_keyboard(); continue
            back = [e for e in els if e.kind == "Button" and (e.label == "Back" or e.ident == "BackButton") and e.frame[0] >= 0]
            if back and tapped_back >= 2:
                # The back control is hidden or ignored (e.g. a page whose address bar takes
                # the touch): the interactive edge swipe pops.
                self.sim.drag(2, 400, 320, 400, 0.5, 30, 0.1); time.sleep(1.2); tapped_back = 0; continue
            if back:
                tapped_back += 1
                self.sim.tap_el(back[0]); time.sleep(1.2); continue
            close = [e for e in els if e.kind == "Button" and e.label in ("Close", "Done", "Cancel") and e.frame[0] >= 0]
            if close:
                self.sim.tap_el(close[0]); time.sleep(1.0); continue
            tab = [e for e in els if e.label == "Workspaces" and e.kind == "RadioButton"]
            if tab:
                self.sim.tap_el(tab[0]); time.sleep(1.0); continue
            # A sheet the AX tree does not show (system pickers, Files and links): swipe it down,
            # from the top of a full sheet or from a half sheet's grabber.
            y0 = 300 if sheet_try % 2 == 0 else 425
            sheet_try += 1
            self.sim.drag(201, y0, 201, 870, 0.3, 20, 0.1); time.sleep(1.0)
        raise Fail("could not get back to the Workspaces list")

    def open_seed_workspace(self):
        self.back_to_list()
        row = self.sim.wait(prefix=self.ws_name, kind="Button", timeout=30)
        check(row, f"workspace {self.ws_name} not in the phone's list")
        t = self.sim.tap_el(row)
        el = self.sim.wait(ident="terminal.composer.field", timeout=20)
        check(el, "terminal composer never appeared")
        return time.time() - t

    def focus_terminal(self):
        """Taps the terminal so its own input (direct typing) owns the soft keyboard."""
        comp = self.sim.wait(ident="terminal.composer.field", timeout=10)
        check(comp, "no terminal on screen")
        y = max(150, comp.frame[1] - 200)
        self.sim.tap(201, y)
        kb = self.sim.wait(label="q", kind="Button", timeout=6)
        if not kb:
            # A keyboard toggle exists on the key bar.
            k = self.sim.find(ident="terminal.keyboardToggle") or self.sim.find(label="Show Keyboard")
            if k:
                self.sim.tap_el(k[0])
                kb = self.sim.wait(label="q", kind="Button", timeout=6)
        check(kb, "software keyboard did not appear for direct typing")
        self.sim.dismiss_keyboard_intro()

    PINNED_KEYS = ("Escape", "Control", "Alt")  # fixed at the key bar's leading edge

    def keybar_lane(self, label):
        # The rest scroll between the pinned keys (about x 175) and the joystick.
        return (13, 175) if label in self.PINNED_KEYS else (178, 300)

    def keybar_reveal(self, label):
        e = self.sim.reveal_h(dict(label=label, kind="Button"), lane=self.keybar_lane(label), tries=30)
        check(e, f"key bar has no {label!r}")
        return e

    def keybar(self, label):
        # The key bar scrolls between its left edge and the joystick / hide-keyboard buttons.
        e = self.sim.reveal_h(dict(label=label, kind="Button"), lane=self.keybar_lane(label), tries=30)
        check(e, f"key bar has no {label!r}")
        return self.sim.tap_el(e)

    def hide_keyboard(self):
        """Hides the software keyboard (the key bar's button, else a drag down on the page)."""
        for _ in range(2):
            els = self.sim.tree()
            if not self.sim.keyboard(els):
                return
            e = self.sim.find(label="Hide Keyboard", elements=els)
            if e:
                self.sim.tap_el(e[0])
            else:
                self.sim.drag(201, 300, 201, 700, 0.3, 20, 0.1)
            time.sleep(0.8)

    # ------------------------------------------------------------------ setup
    def cleanup_mac(self):
        """Closes the rig's own e2e-* and phone-made workspaces from earlier runs."""
        for w in self.mac.cmux("workspace", "list", json_out=True) or []:
            if re.match(r"^(e2e-\d{6}|New Workspace( \d+)?)$", w.get("name") or ""):
                self.mac.cmux("workspace", w["id"], "close", check=False)

    def seed_mac(self):
        self.cleanup_mac()
        r = self.mac.cmux("workspace", "create", "--name", self.ws_name, json_out=True)["value"]
        t2 = self.mac.cmux("tab", "create", "terminal", "--workspace", r["workspace_id"], json_out=True)["value"]
        self.seed = {"ws": r["workspace_id"], "term1": r["terminal_id"], "tab1": r["tab_id"],
                     "term2": t2["terminal_id"], "tab2": t2["tab_id"]}
        self.mac.cmux("tab", r["tab_id"], "rename", "e2e-t1")
        self.mac.cmux("tab", t2["tab_id"], "rename", "e2e-t2")
        self.mac.cmux("tab", r["tab_id"], "focus", check=False)
        self.device_id = None
        for _ in range(60):
            self.device_id = self.mac.device_id()
            if self.device_id:
                break
            time.sleep(1)
        return self.seed

    def which_term(self, marker):
        for k in ("term1", "term2"):
            if marker in self.mac_screen(self.seed[k]).get("text", ""):
                return self.seed[k]
        return None

    # ================================================================== steps
    def s_fresh_install(self):
        self.sim.terminate(BUNDLE)
        subprocess.run(["xcrun", "simctl", "uninstall", self.sim.udid, BUNDLE], capture_output=True)
        # A new phone: the simulator keychain outlives an uninstall, as on a device.
        subprocess.run(["xcrun", "simctl", "keychain", self.sim.udid, "reset"], capture_output=True)
        subprocess.run(["xcrun", "simctl", "install", self.sim.udid, self.app_path], check=True, capture_output=True)
        t = self.sim.launch(BUNDLE)
        e = self.sim.wait(label="Continue with email", kind="Button", timeout=30)
        check(e, "Welcome never showed sign-in choices")
        texts = [x for x in self.sim.texts() if len(x) > 8][:6]
        return {"notes": f"Welcome in {time.time()-t:.1f} s: {texts[:3]}"}

    def s_sign_in(self):
        self.sim.tap_q(label="Continue with email", kind="Button")
        f = self.sim.wait(kind="TextField", timeout=10)
        check(f, "email field missing")
        self.sim.dismiss_keyboard_intro()
        self.sim.softtype("42")
        go = [e for e in self.sim.find(kind="Button") if e.label in ("Send code", "Continue") and e.frame[1] < 560]
        check(go, "no Send code / Continue button on the email step")
        t = self.sim.tap_el(go[0])
        i, _ = self.sim.wait_any([dict(ident="setup.teams.create"), dict(ident="setup.teams.choose"),
                                  dict(contains="Connect your Mac"), dict(label="Workspaces", kind="RadioButton")], timeout=40)
        check(i is not None, "sign-in did not finish within 40 s")
        return {"notes": f"signed in with the DEBUG dev credential (email 42) in {time.time()-t:.1f} s",
                "metric_signin_s": round(time.time() - t, 2)}

    def s_choose_space(self):
        i, _ = self.sim.wait_any([dict(ident="setup.teams.create"), dict(ident="setup.teams.choose"),
                                  dict(contains="Connect your Mac"), dict(label="Workspaces", kind="RadioButton")], timeout=20)
        notes = []
        if i in (0, 1):
            nn = self.sim.find(label="Not now", kind="Button")
            personal = self.sim.find(ident="setup.teams.personal")
            if personal:
                self.sim.tap_el(personal[0]); notes.append("space: Personal")
            elif nn:
                self.sim.tap_el(nn[0]); notes.append("team: Not now (personal space)")
            else:
                p = self.sim.find(contains="Personal", kind="Button")
                check(p, "no personal choice on the team step")
                self.sim.tap_el(p[0]); notes.append("team: Personal")
            i, _ = self.sim.wait_any([dict(contains="Connect your Mac"), dict(label="Workspaces", kind="RadioButton")], timeout=20)
        if i is not None and self.sim.find(contains="Connect your Mac"):
            st = self.sim.wait(ident="connect-mac.status", timeout=30)
            notes.append(f"connect step: {st.label if st else 'no status'}")
            self.sim.tap_q(label="Continue", kind="Button")
            time.sleep(1.5)
        if self.sim.find(label="Turn on notifications"):
            self.sim.tap_q(label="Not now", kind="Button"); notes.append("notifications: Not now")
        check(self.sim.wait(label="Workspaces", kind="RadioButton", timeout=20), "never reached the tab bar")
        return "; ".join(notes)

    def s_mac_discovered(self):
        self.tab("Workspaces")
        check(self.device_id, "the rig Mac has no cnx-hostd device id (Allow iPhone Connections off?)")
        if self.sim.wait(ident="workspaces.filter", timeout=8) and not self.sim.find(ident="workspaces.chip.*"):
            return self.mac_discovered_filter()
        lies, t0 = [], time.time()
        chip = None
        while time.time() - t0 < 45:
            els = self.sim.tree()
            for e in els:
                if (e.ident or "").startswith("workspaces.empty") or "No workspaces" in (e.label or ""):
                    lies.append(f"{e.label or e.ident}@{time.time()-t0:.1f}s")
            if self.sim.find(ident=f"workspaces.chip.{self.device_id}", elements=els):
                chip = self.sim.reveal_h(dict(ident=f"workspaces.chip.{self.device_id}"))
                if chip:
                    break
            time.sleep(0.5)
        check(chip, f"rig Mac (device {self.device_id}) never listed on the phone in 45 s")
        t = self.sim.tap_el(chip)
        st = self.watch_link(t, 12, lies)
        fallback = None
        if st is None:
            # The chip only filters; the link stays on another online Mac. The chip's
            # context menu (long press) has Reconnect, which retargets the link.
            fallback = "chip tap left the link on another Mac; used long-press > Reconnect"
            chip = self.sim.reveal_h(dict(ident=f"workspaces.chip.{self.device_id}"))
            self.sim.long_press(*chip.center, seconds=1.0)
            time.sleep(1.2)
            t2 = self.sim.tap_q(label="Reconnect", timeout=5)
            st = self.watch_link(t2, 30, [])
        check(st, "link never reached Connected for the rig Mac")
        self.linked_s = time.time() - t
        check(not lies and not fallback, f"selecting the online rig Mac ({chip.label}) showed "
              f"{sorted(set(l.split('@')[0] for l in lies))[:2]} at {[l.split('@')[1] for l in lies][:3]}; "
              f"{fallback or ''}; the list filter does not retarget the link (WorkspacesList.select -> MacFilter only; "
              f"LiveCoordinator.select is reached only from Reconnect)")
        return {"notes": f"{chip.label} [{chip.value}] -> '{st}' in {time.time()-t:.1f} s"}

    def lie_scan(self, els, t, lies):
        for e in els:
            if (e.ident or "").startswith("workspaces.empty") or "No workspaces" in (e.label or ""):
                lies.append(f"{e.label or e.ident}@{time.time()-t:.1f}s")

    def mac_discovered_filter(self):
        lies, t0 = [], time.time()
        for _ in range(4):
            self.lie_scan(self.sim.tree(), t0, lies)
        t = self.choose_mac()
        rows = None
        while time.time() - t < 30:
            els = self.sim.tree()
            self.lie_scan(els, t, lies)
            if self.sim.find(prefix=self.ws_name, kind="Button", elements=els):
                rows = time.time() - t
                break
            time.sleep(0.3)
        check(rows is not None, f"the rig Mac's workspaces never listed within 30 s of choosing it; lies {lies[:3]}")
        st = self.link_status()
        dt = self.wait_connected(30) if "Connected" not in st else 0.0
        st = st if "Connected" in st else self.link_status()
        check(dt is not None, f"rows shown, but the link never reached Connected ({st!r})")
        check(not lies, f"empty state shown while the Mac was online: {sorted(set(l.split('@')[0] for l in lies))[:2]} "
                        f"at {[l.split('@')[1] for l in lies][:4]}")
        return {"notes": f"Filter > rig Mac: rows in {rows:.1f} s; link '{st}'"}

    def watch_link(self, t, timeout, lies):
        while time.time() - t < timeout:
            els = self.sim.tree()
            for e in els:
                if (e.ident or "").startswith("workspaces.empty") or "No workspaces" in (e.label or ""):
                    lies.append(f"{e.label or e.ident}@{time.time()-t:.1f}s")
            s = self.sim.find(ident="mac-link-status", elements=els)
            if s and "Connected" in (s[0].label or "") and self.sim.find(ident="workspace.row.*", elements=els):
                return s[0].label
            time.sleep(0.3)
        return None

    def s_workspace_list(self):
        self.back_to_list()
        mac = [w["name"] for w in self.mac.cmux("workspace", "list", json_out=True)]
        deadline = time.time() + 20
        phone = []
        while time.time() < deadline:
            phone = sorted({(e.label or "").split(",")[0] for e in self.sim.find(ident="workspace.row.*", kind="Button")})
            if self.ws_name in phone:
                break
            time.sleep(0.5)
        missing = [n for n in mac if n not in phone]
        extra = [n for n in phone if n not in mac]
        check(self.ws_name in phone, f"seeded workspace {self.ws_name} missing on the phone; phone shows {phone}")
        check(not missing and not extra, f"list mismatch: missing {missing}, extra {extra}")
        return f"{len(phone)} rows match the Mac ({', '.join(phone[:6])})"

    def s_create_workspace(self):
        self.back_to_list()
        before = {w["id"] for w in self.mac.cmux("workspace", "list", json_out=True)}
        t = self.sim.tap_q(ident="workspaces.new")
        new, kind, t_open = None, None, None
        while time.time() - t < 20:
            els = self.sim.tree()
            if kind is None:
                if self.sim.find(ident="terminal.composer.field", elements=els):
                    kind, t_open = "terminal", time.time() - t
                elif self.sim.find(contains="Search or enter website", elements=els):
                    kind, t_open = "browser address bar", time.time() - t
                    self.sim.shot(f"create-page-{self.run_id}")
            now = self.mac.cmux("workspace", "list", json_out=True)
            new = [w for w in now if w["id"] not in before]
            if new and kind:
                break
            time.sleep(0.3)
        t_mac = time.time() - t
        self.back_to_list()
        if new:
            self.mac.cmux("workspace", new[0]["id"], "close", check=False)
        check(new, f"tap New Workspace: no workspace reached the Mac in 20 s; the phone showed {kind or 'nothing'} "
                   f"(optimistic page {'never confirmed' if kind else 'missing'})")
        check(kind == "terminal", f"the new workspace opened on {kind}, expected the Mac's default terminal")
        return {"notes": f"'{new[0]['name']}' on the Mac in {t_mac:.2f} s; phone showed its terminal in {t_open:.2f} s (closed afterwards)",
                "metric_create_mac_s": round(t_mac, 2)}

    def s_open_workspace(self):
        dt = self.open_seed_workspace()
        title = [e.label for e in self.sim.find(kind="Button") if (e.label or "").startswith(("e2e-t", "azizalbahar", "~"))]
        return {"notes": f"opened {self.ws_name} on a terminal in {dt:.2f} s; toolbar {title[:2]}"}

    def tab_grid_pick(self, name):
        self.dismiss_system()
        self.hide_keyboard()
        self.sim.tap_q(label="Tabs", kind="Button")
        time.sleep(1.2)
        cand = self.sim.wait(suffix=name, kind="Button", timeout=8)
        if cand and cand.label != name:
            self.grid_notes.append(f"grid card '{cand.label}'")
        check(cand, f"tab grid has no {name}")
        self.sim.tap_el(cand)
        time.sleep(1.5)

    def current_tab_marker(self):
        """Writes a marker through the phone's terminal and returns which Mac terminal got it."""
        marker = f"m{random.randint(10000, 99999)}"
        self.sim.tap_q(ident="terminal.composer.field")
        time.sleep(0.6)
        self.sim.dismiss_keyboard_intro()
        self.sim.softtype(f"echo {marker}")
        self.sim.tap_q(ident="terminal.composer.send")
        time.sleep(2.0)
        self.hide_keyboard()
        return self.which_term(marker)

    def s_last_tab_restore(self):
        self.open_seed_workspace()
        self.tab_grid_pick("e2e-t2")
        term = self.current_tab_marker()
        check(term == self.seed["term2"], f"after picking e2e-t2 input reached {term}, expected {self.seed['term2']}")
        self.back_to_list()
        self.open_seed_workspace()
        term = self.current_tab_marker()
        check(term == self.seed["term2"], f"reopened workspace did not restore e2e-t2 (input went to {term})")
        self.tab_grid_pick("e2e-t1")
        term = self.current_tab_marker()
        check(term == self.seed["term1"], "switching back to e2e-t1 failed")
        return "reopened on the last tab (e2e-t2); grid switch back to e2e-t1"

    def s_term_direct(self):
        self.open_seed_workspace()
        self.focus_terminal()
        marker = f"d{random.randint(10000, 99999)}"
        self.sim.softtype(f"echo {marker}\n")
        self.mac_wait_text(self.seed["term1"], marker, count=2)
        return f"typed 'echo {marker}' + return on the software keyboard; the Mac ran it"

    def s_term_composer(self):
        self.open_seed_workspace()
        self.hide_keyboard()
        self.sim.tap_q(ident="terminal.composer.field")
        time.sleep(0.6)
        marker = f"c{random.randint(10000, 99999)}"
        self.sim.softtype(f"echo {marker}")
        self.sim.tap_q(ident="terminal.composer.send")
        self.mac_wait_text(self.seed["term1"], marker, count=2)
        self.hide_keyboard()
        return f"composer sent 'echo {marker}'"

    def s_term_keys(self):
        self.open_seed_workspace()
        term = self.seed["term1"]
        notes, problems = [], []
        self.focus_terminal()
        # Each key is revealed (the key bar scrolled) BEFORE anything is typed on the line.
        # ^C interrupts a running command.
        self.keybar_reveal("Control C")
        self.sim.softtype("sleep 300\n")
        time.sleep(1.5)
        self.keybar("Control C")
        self.mac_wait_text(term, "^C", timeout=8)
        notes.append("^C interrupted sleep")
        # Up arrow recalls history; Return runs it again.
        self.keybar_reveal("Up Arrow")
        marker = f"u{random.randint(10000, 99999)}"
        self.sim.softtype(f"echo {marker}\n")
        self.mac_wait_text(term, marker, count=2)
        self.keybar("Up Arrow")
        time.sleep(0.4)
        self.sim.softtype("\n")
        self.mac_wait_text(term, marker, count=4)
        notes.append("Up Arrow recalled the last command")
        # Left arrow edits mid-line: abd, Left, c -> abcd.
        self.keybar_reveal("Left Arrow")
        self.sim.softtype("echo abd")
        self.keybar("Left Arrow")
        self.sim.softtype("c\n")
        self.mac_wait_text(term, "abcd", timeout=8)
        notes.append("Left Arrow moved the cursor (abd -> abcd)")
        # Does scrolling the key bar type the key under the finger?
        line = f"echo k{random.randint(1000, 9999)}"
        self.sim.softtype(line)
        time.sleep(1)
        before = self.mac_screen(term).get("text", "").rstrip().splitlines()[-1]
        self.keybar_reveal("Paste")
        self.keybar_reveal("Left Arrow")
        time.sleep(1)
        after = self.mac_screen(term).get("text", "").rstrip().splitlines()[-1]
        if before != after:
            problems.append(f"scrolling the key bar sent keys: line {before!r} -> {after!r}")
        self.keybar_reveal("Control C"); self.keybar("Control C")
        # Joystick: drag left, the cursor moves.
        js = self.sim.find(label="Cursor joystick")
        if js:
            self.sim.softtype("echo xyz")
            time.sleep(1)
            before = self.mac_screen(term).get("cursor_col")
            cx, cy = js[0].center
            self.sim.drag(cx, cy, cx - 40, cy, duration=0.6, hold=0.4)
            time.sleep(0.8)
            after = self.mac_screen(term).get("cursor_col")
            self.keybar_reveal("Control C"); self.keybar("Control C")
            if not (after is not None and before is not None and after < before):
                problems.append(f"joystick did not move the cursor ({before} -> {after})")
            else:
                notes.append(f"joystick moved the cursor {before}->{after}")
        else:
            problems.append("no joystick on the key bar")
        self.hide_keyboard()
        check(not problems, "; ".join(problems) + " | ok: " + "; ".join(notes))
        return "; ".join(notes)

    def s_term_tui(self):
        self.open_seed_workspace()
        term = self.seed["term1"]
        path = f"/tmp/cnx-e2e-{self.run_id}.txt"
        self.focus_terminal()
        self.sim.softtype(f"vim -u NONE {path}\n")
        self.mac_wait_text(term, "~", timeout=8, count=5)
        self.sim.softtype("ihello e2e")
        self.keybar("Escape")
        self.sim.softtype(":wq\n")
        deadline = time.time() + 10
        while time.time() < deadline and not os.path.exists(path):
            time.sleep(0.3)
        check(os.path.exists(path) and "hello e2e" in open(path).read(), "vim edit did not reach the Mac file")
        # top as the htop stand-in (htop is not installed on this Mac).
        self.sim.softtype("top\n")
        self.mac_wait_text(term, "Processes", timeout=10)
        shot = self.sim.shot(f"tui-top-{self.run_id}")
        self.sim.softtype("q")
        time.sleep(1)
        marker = f"t{random.randint(10000, 99999)}"
        self.sim.softtype(f"echo {marker}\n")
        self.mac_wait_text(term, marker, count=2)
        self.hide_keyboard()
        return f"vim wrote {path}; top ran and quit; shell responsive after (htop not installed)"

    def s_scrollback(self):
        self.open_seed_workspace()
        term = self.seed["term1"]
        self.mac_write(term, "clear; seq 1 400\n")
        self.mac_wait_text(term, "400", timeout=8)
        time.sleep(1.5)
        a = self.sim.shot(f"scroll-a-{self.run_id}")
        for _ in range(4):
            self.sim.drag(201, 250, 201, 650, duration=0.4, hold=0.2)
        time.sleep(1)
        b = self.sim.shot(f"scroll-b-{self.run_id}")
        check(open(a, "rb").read() != open(b, "rb").read(), "dragging the terminal did not scroll")
        jump = self.sim.find(contains="bottom") or self.sim.find(contains="Jump")
        if jump:
            self.sim.tap_el(jump[0]); time.sleep(1)
        else:
            for _ in range(5):
                self.sim.drag(201, 650, 201, 150, duration=0.3, hold=0.1)
        return "scrolled back through 400 lines" + ("; jump-to-bottom tapped" if jump else "; no jump button found (dragged back)")

    def s_files_links(self):
        self.open_seed_workspace()
        term = self.seed["term1"]
        sample = f"/tmp/cnx-e2e-{self.run_id}-sample.md"
        open(sample, "w").write(f"# e2e sample {self.run_id}\n\nhello from the Mac\n")
        self.mac_write(term, f"clear; ls -l {sample}; echo https://cmux.com\n")
        self.mac_wait_text(term, "cmux.com", timeout=8, count=1)
        time.sleep(1)
        self.hide_keyboard()
        # The tab title capsule in the bottom toolbar opens the tab's menu.
        title = [e for e in self.sim.find(kind="Button") if e.frame[1] > 780 and e.frame[2] > 150]
        check(title, "no tab title capsule on the terminal toolbar")
        self.sim.tap_el(title[0]); time.sleep(1.2)
        self.sim.tap_q(label="Files and Links", timeout=6)
        time.sleep(2.5)
        notes = []
        if not self.sim.find(contains="Files and links"):
            notes.append("the Files and links sheet is invisible to accessibility (VoiceOver cannot use it); read by OCR")
        rows = self.sim.ocr_find(os.path.basename(sample), timeout=6)
        link = self.sim.ocr_find("cmux.com")
        try:
            check(rows, f"Files and links did not list {sample}")
            x, y, w, h, _ = rows[0]
            self.sim.tap(201, y + h / 2)
            prev = self.sim.ocr_find("hello from the Mac", timeout=10)
            self.sim.shot(f"files-preview-{self.run_id}")
            if not prev:
                src = self.sim.find(label="Source", kind="RadioButton")
                if src:
                    self.sim.press(*src[0].center, hold=0.1)
                    shown = self.sim.ocr_find("hello from the Mac", timeout=6)
                    notes.append("Source view " + ("shows the text" if shown else "is blank too"))
            check(prev, f"the Preview of {os.path.basename(sample)} stayed blank for 10 s (the Mac file has text)"
                        + ("; " + "; ".join(notes) if notes else ""))
        finally:
            for _ in range(2):
                self.sim.drag(201, 470, 201, 870, 0.3, 20, 0.1); time.sleep(1)
        return "; ".join([f"listed and previewed {os.path.basename(sample)}", "link listed" if link else "link NOT listed"] + notes)

    def s_image_upload(self):
        self.open_seed_workspace()
        add = self.sim.wait(label="Add attachment", timeout=8)
        check(add, "no Add attachment button on the terminal composer")
        self.sim.press(*add.center, hold=0.1); time.sleep(1.2)
        files = self.sim.find(label="Files", kind="Button")
        photos = self.sim.find(label="Photos", kind="Button")
        check(files or photos, "attachment menu did not open")
        # Photos is drawn under Files but missing from the accessibility tree.
        x, y = photos[0].center if photos else (files[0].center[0], files[0].center[1] + 63)
        self.sim.press(x, y, hold=0.1); time.sleep(3)
        # The system photo picker runs out of process (no accessibility here): fixed spots
        # on the 402x874 pt screen: first library photo, then the checkmark.
        self.sim.tap(200, 412); time.sleep(1)
        self.sim.tap(363, 144); time.sleep(2.5)
        chip = [e for e in self.sim.find(kind="Image") if re.search(r"\.(jpe?g|png|heic)$", e.label or "", re.I)]
        if not chip:
            self.sim.drag(201, 300, 201, 860, 0.3, 20, 0.1)  # dismiss the picker
        check(chip, "no image attached after picking a photo")
        name = chip[0].label
        self.sim.tap_q(ident="terminal.composer.send")
        time.sleep(4)
        errors = [e.label for e in self.sim.tree() if re.search(r"couldn.t send|failed|error", e.label or "", re.I)]
        for e in self.sim.find(kind="Button"):
            if (e.label or "").startswith("Remove "):  # leave the composer clean for later steps
                self.sim.tap_el(e); time.sleep(0.5)
        text = self.mac_screen(self.seed["term1"]).get("text", "")
        flat = text.replace("\n", "").replace("\\ ", " ")
        paths = re.findall(r"(~?/[^❯'\"]*?\.(?:jpe?g|png|heic))", flat, re.I)
        check(not errors, f"the phone reported: {errors[0] if errors else ''}")
        check(paths, f"the phone sent {name} but no path reached the Mac terminal; tail {text[-160:]!r}")
        p = os.path.expanduser(paths[-1].strip())
        check(os.path.exists(p) and os.path.getsize(p) > 0,
              f"the phone typed {paths[-1]} into the shell, but no such file exists on the Mac (upload never happened); "
              f"shell said: {text.strip().splitlines()[-3:] }")
        return f"{name} uploaded to {paths[-1]} ({os.path.getsize(p)} bytes)"

    def s_agent_chat(self):
        raise Blocked("no credit-free REAL harness on this Mac: no local model server (Ollama/LM Studio not installed) "
                      "and cmux-next has no built-in echo harness; Claude/Codex would make paid model calls. "
                      "Streaming, tool calls, Allow/Deny (Face ID), question answer, attachments, diff viewer and artifacts not run.")

    def s_feed(self):
        self.back_to_list()
        self.tab("Feed")
        texts = [str(e.label) for e in self.sim.tree() if e.label and 0 <= e.frame[0] < 402 and 100 < e.frame[1] < 780][:6]
        raise Blocked(f"Feed events come from agent asks; no credit-free harness (see agent_chat). Feed opened: {texts[:4]}")

    def s_chief(self):
        self.back_to_list()
        self.tab("Home")
        self.sim.tap_q(ident="home.chief")
        t = time.time()
        loaded = None
        while time.time() - t < 25:
            els = self.sim.tree()
            if not self.sim.find(ident="conversation.initialLoading", elements=els) and self.sim.find(ident="conversation.transcript", elements=els):
                loaded = time.time() - t
                break
            time.sleep(0.5)
        self.sim.shot(f"chief-{self.run_id}")
        bubbles = [e.label for e in self.sim.find(ident="conversation.transcript")] if loaded else []
        engine = self.mac.cmux("chief", "engine", check=False, timeout=30)
        eng = (engine.stdout or engine.stderr).strip()[:200]
        model = [e.label for e in self.sim.tree() if re.search(r"model|sonnet|opus|gpt|haiku", e.label or "", re.I) and 0 <= e.frame[0] < 402]
        self.back_to_list()
        check(loaded is not None, f"Chief never loaded: the conversation spinner (conversation.initialLoading) was still up after 25 s; "
                                  f"no model picker on the screen; Mac CLI `cmux chief engine`: {eng}")
        raise Blocked(f"Chief loaded in {loaded:.1f} s; send/receive not run (a paid model call). Model controls: {model[:3] or 'none'}; Mac engine: {eng}")

    def settings_find(self, timeout=8, **q):
        """Finds a row on the Settings page, scrolling up then down."""
        for d in [(250, 750)] * 3 + [(650, 250)] * 6:
            e = self.sim.find(**q)
            if e and 100 < e[0].center[1] < 780:
                return e[0]
            self.sim.drag(201, d[0], 201, d[1], 0.4, 20, 0.2); time.sleep(0.6)
        return None

    def settings_transport(self, name):
        self.tab("Settings")
        cur = self.settings_find(contains="Transport,", kind="PopUpButton")
        check(cur, "no Transport picker")
        if cur.label.endswith(name):
            return 0.0
        self.sim.press(cur.frame[0] + cur.frame[2] - 60, cur.center[1], hold=0.1); time.sleep(1.2)
        item = self.sim.wait(label=name, kind="Button", timeout=5)
        check(item, f"transport menu did not open")
        self.sim.press(*item.center, hold=0.1)
        t = time.time()
        self.tab("Workspaces")
        lab = ""
        while time.time() - t < 30:
            lab = self.link_status()
            if "Connected" in lab and name.lower() in lab.lower():
                return time.time() - t
            time.sleep(0.3)
        raise Fail(f"{name}: link not Connected over {name} after 30 s ({lab!r})")

    def term_roundtrip(self):
        self.open_seed_workspace()
        m = self.current_tab_marker()
        check(m is not None, "terminal input did not reach the Mac")
        self.back_to_list()

    def s_transport(self):
        a = self.settings_transport("WireGuard")
        self.term_roundtrip()
        b = self.settings_transport("WebRTC")
        self.term_roundtrip()
        return {"notes": f"WireGuard Connected in {a:.1f} s, back to WebRTC in {b:.1f} s; terminal input worked on both",
                "metric_wg_switch_s": round(a, 2), "metric_webrtc_switch_s": round(b, 2)}

    def relay_toggle(self, want):
        """Sets Settings > Developer > Relay only to `want` ("1"/"0"); returns (before, after)."""
        self.tab("Settings")
        e = self.settings_find(contains="Relay only", kind="CheckBox")
        check(e, "no 'Relay only' toggle in Settings > Developer")
        before = e.value
        for _ in range(3):
            if e.value == want:
                break
            self.sim.press(e.frame[0] + e.frame[2] - 40, e.center[1], hold=0.1)
            time.sleep(1.2)
            e = self.settings_find(contains="Relay only", kind="CheckBox")
        return before, e.value if e else None

    def s_relay_only(self):
        b, a = self.relay_toggle("1")
        check(a == "1", f"Relay only did not turn on ({b} -> {a})")
        t = time.time()
        self.tab("Workspaces")
        seen, st = [], None
        while time.time() - t < 40:
            lab = self.link_status()
            if lab and (not seen or seen[-1][1] != lab):
                seen.append((round(time.time() - t, 1), lab))
            if "Connected" in lab and re.search(r"relay|turn", lab, re.I):
                st = lab; break
            time.sleep(0.4)
        dt = time.time() - t
        ok = st is not None
        if ok:
            self.term_roundtrip()
        b2, a2 = self.relay_toggle("0")
        check(ok, f"relay-only: never 'Connected' via relay/TURN in 40 s; status sequence {seen[:6]}")
        return {"notes": f"'{st}' in {dt:.1f} s; terminal worked over the relay; toggled back off (value {a2})",
                "metric_relay_connect_s": round(dt, 2)}

    def s_sign_out_in(self):
        self.tab("Settings")
        for _ in range(6):
            if self.sim.find(ident="settings.logout"):
                break
            self.sim.drag(201, 650, 201, 250, duration=0.4, hold=0.2)
        lo = self.settings_find(ident="settings.logout")
        check(lo, "no Log out row in Settings")
        self.sim.tap_el(lo)
        time.sleep(1.2)
        conf = [e for e in self.sim.find(label="Log out", kind="Button") if e.ident != "settings.logout"]
        check(conf, "no Log out confirmation")
        self.sim.press(*conf[-1].center, hold=0.1)
        check(self.sim.wait(label="Continue with email", kind="Button", timeout=20), "sign-out did not return to Welcome")
        self.s_sign_in()
        self.s_choose_space()
        self.s_mac_discovered()
        return "signed out to Welcome, signed back in and relinked the rig Mac"

    def link_status(self):
        """The rig Mac's link line. Old list: the status row. Redesigned list: the
        subtitle of the rig Mac in the Filter menu (read by OCR; AX has only the name)."""
        s = self.sim.find(ident="mac-link-status")
        if s:
            return s[0].label or ""
        f = self.sim.find(ident="workspaces.filter")
        if not f:
            return ""
        self.sim.press(*f[0].center, hold=0.1)
        item = self.sim.wait(ident=f"workspaces.filter.{self.device_id}", timeout=4)
        text = ""
        if item:
            x, y, w, h = item.frame
            text = " ".join(o[4] for o in self.sim.ocr() if y - 2 <= o[1] <= y + h and o[0] >= x - 4)
        self.sim.tap(60, 450)  # outside the menu: dismiss without choosing
        time.sleep(0.6)
        return text

    def choose_mac(self):
        """Redesigned list: Filter > the rig Mac. Returns the tap time."""
        f = self.sim.wait(ident="workspaces.filter", timeout=10)
        check(f, "no Filter button on Workspaces")
        self.sim.press(*f.center, hold=0.1)
        item = self.sim.wait(ident=f"workspaces.filter.{self.device_id}", timeout=6)
        check(item, f"the Filter menu does not list the rig Mac ({self.device_id})")
        return self.sim.press(*item.center, hold=0.1)

    def wait_connected(self, timeout):
        t = time.time()
        while time.time() - t < timeout:
            if "Connected" in self.link_status():
                return time.time() - t
            time.sleep(0.25)
        return None

    def s_background(self):
        self.back_to_list()
        check(self.wait_connected(20) is not None, "not connected before backgrounding")
        self.sim.home()
        time.sleep(45)
        t = self.sim.launch(BUNDLE, terminate=False)  # the running app back to the foreground
        dt = self.wait_connected(30)
        check(dt is not None, f"no Connected within 30 s of foreground ({self.link_status()})")
        self.term_roundtrip()
        return {"notes": f"45 s in background; Connected {dt:.2f} s after foreground; terminal input reached the Mac",
                "metric_foreground_reconnect_s": round(dt, 2)}

    def s_mac_restart(self):
        self.back_to_list()
        self.mac.quit()
        t = time.time()
        off = None
        while time.time() - t < 40:
            st = self.link_status()
            if st and "Connected" not in st:
                off = time.time() - t; break
            time.sleep(0.5)
        offline_label = self.link_status()
        self.mac.launch()
        self.mac.wait_hostd(120)
        t2 = time.time()
        dt = self.wait_connected(90)
        check(off is not None, f"phone kept showing Connected for 40 s after the Mac quit ({offline_label})")
        check(dt is not None, "phone did not reconnect within 90 s of the Mac relaunch")
        self.term_roundtrip()
        return {"notes": f"offline shown {off:.1f} s after quit ('{offline_label}'); reconnected {dt:.1f} s after cnx-hostd was back; terminal OK",
                "metric_mac_relaunch_reconnect_s": round(dt, 2)}

    def s_device_removal(self):
        """Settings > Paired Macs > swipe the rig Mac > Remove. It must leave the phone's
        Mac list and stay gone (the rig Mac keeps running with iPhone connections on).
        The row is found by the rig Mac's device id, never by name: the dev account
        lists several Macs with the same name."""
        check(self.device_id, "the rig Mac has no cnx-hostd device id; refusing to pick a Mac to remove by name")
        row_id = f"settings.pairedMacs.{self.device_id}"
        self.back_to_list()
        self.tab("Settings")
        pm = self.settings_find(contains="Paired Macs", kind="Button")
        check(pm, "no Paired Macs row in Settings")
        self.sim.tap_el(pm); time.sleep(2.5)
        row = self.settings_find(ident=row_id)
        check(row, f"the rig Mac (device {self.device_id}) is not in Paired Macs")
        y = row.center[1]
        self.sim.drag(370, y, 120, y, 0.4, 20, 0.2); time.sleep(1)
        rm = self.sim.wait(label="Remove", kind="Button", timeout=4)
        check(rm, "no Remove action on the row's trailing swipe")
        self.sim.tap_el(rm); time.sleep(1.2)
        conf = [e for e in self.sim.find(label="Remove", kind="Button")]
        check(conf, "no Remove confirmation")
        msg = [e.label for e in self.sim.tree() if "leaves the Mac list" in (e.label or "")]
        self.sim.press(*conf[-1].center, hold=0.1)
        t = time.time()
        gone = None
        while time.time() - t < 20:
            if not self.sim.find(ident=row_id):
                gone = time.time() - t
                break
            time.sleep(1)
        err = [e.label for e in self.sim.tree() if "Couldn't remove" in (e.label or "")]
        check(not err, f"removal failed: {err}")
        check(gone is not None, "the rig Mac stayed in Paired Macs 20 s after Remove")
        time.sleep(30)
        self.back_to_list()
        f = self.sim.find(ident="workspaces.filter")
        back = None
        if f:
            self.sim.press(*f[0].center, hold=0.1)
            back = self.sim.wait(ident=f"workspaces.filter.{self.device_id}", timeout=3)
            self.sim.tap(60, 450)
        check(back is None, "the removed rig Mac came back in the phone's Mac list within 30 s (cmux on it is still running)")
        return {"notes": f"removed in {gone:.1f} s; still gone 30 s later; dialog: {msg[:1]}"}

    def mac_name(self):
        return None

    # ------------------------------------------------------------------ plan
    def plan(self):
        return [
            ("fresh_install", "Fresh install and Welcome", "wsdesign", self.s_fresh_install),
            ("sign_in", "Sign in (dev account, email 42)", "prodinfra", self.s_sign_in),
            ("choose_space", "Choose team / personal, setup steps", "wsdesign", self.s_choose_space),
            ("mac_discovered", "Mac discovered, no false 'No workspaces'", "fastconn", self.s_mac_discovered),
            ("workspace_list", "Workspaces list filtered by Mac matches the Mac", "dataflow", self.s_workspace_list),
            ("create_workspace", "Create workspace (instant)", "dataflow", self.s_create_workspace),
            ("open_workspace", "Open workspace", "wsdesign", self.s_open_workspace),
            ("last_tab_restore", "Last-tab restore and tab grid", "wsdesign", self.s_last_tab_restore),
            ("term_direct", "Terminal: direct typing (soft keyboard)", "termlive", self.s_term_direct),
            ("term_composer", "Terminal: composer", "termlive", self.s_term_composer),
            ("term_keys", "Terminal: ^C, arrows, joystick", "termlive", self.s_term_keys),
            ("term_tui", "Terminal: vim and top TUI", "termlive", self.s_term_tui),
            ("term_scrollback", "Terminal: scrollback", "termlive", self.s_scrollback),
            ("files_links", "Terminal: Files and Links preview", "termlive", self.s_files_links),
            ("image_upload", "Terminal: image upload", "termlive", self.s_image_upload),
            ("agent_chat", "Agent chat (stream, tools, approvals, question, attachments, diff, artifacts)", "approvals", self.s_agent_chat),
            ("feed", "Feed events and inline answer", "approvals", self.s_feed),
            ("chief", "Chief: real Mac conversation, send/receive, model", "chieflive", self.s_chief),
            ("transport", "Transport WebRTC <-> WireGuard", "fastconn", self.s_transport),
            ("relay_only", "Relay only", "fastconn", self.s_relay_only),
            ("sign_out_in", "Sign out and back in", "prodinfra", self.s_sign_out_in),
            ("background", "Background 45 s / foreground reconnect", "fastconn", self.s_background),
            ("mac_restart", "Mac app quit / relaunch, reconnect", "machost", self.s_mac_restart),
            ("device_removal", "Device removal", "machost", self.s_device_removal),
        ]

    LAST = ("device_removal",)  # run by e2e.py after the latency metrics (it unlinks the Mac)

    def run(self, only=None, skip=(), last=False):
        if not last:
            self.seed_mac()
        for sid, title, owner, fn in self.plan():
            if (sid in self.LAST) != last:
                continue
            if (only and sid not in only) or sid in skip:
                continue
            try:
                self.step(sid, title, owner, fn)
            except Exception as e:  # the rig itself failed around a step: record it and go on
                self.results.append({"id": sid, "title": title, "owner": owner, "status": "fail",
                                     "notes": f"rig error around the step: {e}"[:400], "seconds": 0})
        return self.results
