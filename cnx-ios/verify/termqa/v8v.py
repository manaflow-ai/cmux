"""Round-8 verifier (fresh, termverify8): runs the v8* rig helpers with evidence
redirected to verify8v/ and raw video to ~/cnx-ios-e2e/termqa-raw/tv8v/.

    python3 v8v.py v8_hold TAG [args...]
"""
import importlib
import os
import sys

import tq
import v8

V = os.path.abspath(os.path.join(tq.HERE, "../design/terminal/verify8v"))
RAW = os.path.expanduser("~/cnx-ios-e2e/termqa-raw/tv8v")
os.makedirs(V, exist_ok=True)
os.makedirs(RAW, exist_ok=True)
v8.V6 = V
v8.RAW6 = RAW
tq.RAW = RAW

_rec_start = tq.rec_start


def _rec_start_logged(name):
    path = _rec_start(name)
    v8.ev("rec_start", name=name, path=path, t0=tq.load()["rec"]["t0"])
    return path


tq.rec_start = _rec_start_logged

if __name__ == "__main__":
    mod = importlib.import_module(sys.argv[1])
    sys.argv = [sys.argv[1] + ".py"] + sys.argv[2:]
    mod.main()
