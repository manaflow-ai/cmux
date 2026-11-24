import os
import random
import subprocess
import sys
import textwrap

import undotree
from undotree import UndoTree
from pytest_shim import raises


class Model:
    def __init__(self, text):
        self.texts = {0: text}
        self.par = {0: None}
        self.kids = {0: []}
        self.pref = {}
        self.cur = 0

    def commit(self, text):
        if text != self.texts[self.cur]:
            nid = len(self.texts)
            self.texts[nid] = text
            self.par[nid] = self.cur
            self.kids[nid] = []
            self.kids[self.cur].append(nid)
            self.pref[self.cur] = nid
            self.cur = nid
        return self.cur

    def undo(self):
        p = self.par[self.cur]
        if p is None:
            return False
        self.pref[p] = self.cur
        self.cur = p
        return True

    def redo(self):
        if not self.kids[self.cur]:
            return False
        self.cur = self.pref[self.cur]
        return True

    def goto(self, nid):
        self.cur = nid
        while self.par[nid] is not None:
            self.pref[self.par[nid]] = nid
            nid = self.par[nid]

    def earlier(self, n):
        self.goto(max(0, min(len(self.texts) - 1, self.cur - n)))

    def later(self, n):
        self.goto(max(0, min(len(self.texts) - 1, self.cur + n)))


def test_reported_goto_then_undo_redo_stays_on_branch():
    t = UndoTree("")
    t.commit("a")      # 1
    t.commit("ab")     # 2
    t.undo()
    t.commit("ac")     # 3, now preferred under 1
    t.goto(2)
    assert t.text == "ab"
    assert t.undo() and t.text == "a"
    assert t.redo() and t.current == 2
    t.goto(3)
    t.goto(0)
    assert t.redo() and t.redo() and t.current == 3
    t.goto(2)
    t.goto(3)
    while t.undo():
        pass
    assert t.current == 0
    while t.redo():
        pass
    assert t.current == 3 and t.text == "ac"


def test_undo_remembers_the_branch_it_left():
    t = UndoTree("x")
    t.commit("x1")
    t.commit("x11")
    t.undo()
    t.commit("x12")
    t.undo()
    t.undo()
    t.commit("x2")
    t.undo()
    assert t.children(0) == [1, 4] and t.children(1) == [2, 3]
    assert t.redo() and t.current == 4
    t.undo()
    t.goto(2)
    t.undo()
    t.undo()
    assert t.redo() and t.redo() and t.current == 2


def test_earlier_later_go_by_commit_order():
    t = UndoTree("")
    for s in ["a", "ab", "abc"]:
        t.commit(s)
    t.undo()
    t.undo()
    t.commit("aX")  # 4, child of 1
    t.earlier(1)
    assert t.current == 3 and t.text == "abc"
    t.earlier(10)
    assert t.current == 0
    t.later(2)
    assert t.current == 2
    t.undo()
    assert t.redo() and t.current == 2
    t.later(99)
    assert t.current == 4
    t.undo()
    assert t.redo() and t.current == 4


def test_documented_regressions():
    t = UndoTree("same")
    assert t.commit("same") == 0 and t.last_id == 0
    assert not t.undo() and not t.redo()
    assert t.commit("new") == 1 and t.commit("new") == 1
    assert t.parent(1) == 0 and t.parent(0) is None
    t.undo()
    assert t.commit("new") == 2 and t.children(0) == [1, 2]
    raises(KeyError, t.goto, 3)
    raises(KeyError, t.children, -1)


def test_long_random_sequences_match_model():
    rnd = random.Random(7)
    for _ in range(200):
        t = UndoTree("")
        m = Model("")
        for _ in range(60):
            roll = rnd.random()
            if roll < 0.35:
                s = rnd.choice(["a", "b", "c", "ab", ""])
                assert t.commit(s) == m.commit(s)
            elif roll < 0.6:
                assert t.undo() == m.undo()
            elif roll < 0.8:
                assert t.redo() == m.redo()
            elif roll < 0.9:
                nid = rnd.randrange(len(m.texts))
                t.goto(nid)
                m.goto(nid)
            elif roll < 0.95:
                k = rnd.randint(0, 4)
                t.earlier(k)
                m.earlier(k)
            else:
                k = rnd.randint(0, 4)
                t.later(k)
                m.later(k)
            assert t.current == m.cur and t.text == m.texts[m.cur]
        for nid in m.texts:
            assert t.children(nid) == m.kids[nid] and t.parent(nid) == m.par[nid]


def test_long_history_undo_redo_fast():
    code = textwrap.dedent("""
        import time
        from undotree import UndoTree
        t = UndoTree("")
        start = time.perf_counter()
        for i in range(1, 100001):
            t.commit(str(i))
            if i % 10 == 0:
                t.undo()
                t.commit(str(-i))
        while t.undo():
            pass
        while t.redo():
            pass
        el = time.perf_counter() - start
        assert t.text == "-100000", t.text
        print(el)
    """)
    try:
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=8,
                             cwd=os.path.dirname(os.path.abspath(undotree.__file__)))
    except subprocess.TimeoutExpired:
        raise AssertionError("too slow")
    assert out.returncode == 0, out.stderr[-400:]
    assert float(out.stdout.split()[-1]) < 1.0, out.stdout
