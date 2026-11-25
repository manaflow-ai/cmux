from titlesplit import split_title as sp, store, shown_title


def test_commit_cases():
    assert sp("⠐ Fix the login bug") == ("Fix the login bug", "working")
    assert sp("⠂ Fix the login bug") == ("Fix the login bug", "working")
    assert sp("✳ Claude Code") == ("Claude Code", "idle")
    assert sp("● build") == ("build", "idle")
    assert sp("✔︎ tests passed") == ("tests passed", "done")
    assert sp("✘ deploy") == ("deploy", "failed")
    assert sp("✳ ⠂ Task") == ("Task", "working")


def test_plain_titles():
    assert sp("vim notes.md") == ("vim notes.md", None)
    assert sp("~/src · main") == ("~/src · main", None)
    assert sp("") == ("", None)
    assert sp("  htop  ") == ("htop", None)
    assert sp("⠀ blank braille") == ("⠀ blank braille", None)


def test_edges():
    assert sp("⠂") == ("⠂", "working")
    assert sp("  ✳  ") == ("✳", "idle")
    assert sp("⠂Fix") == ("Fix", "working")
    assert sp("◐ spin") == ("spin", "working")
    assert sp("▖ q") == ("q", "working")
    assert sp("✅ ok") == ("ok", "done")
    assert sp("❌ no") == ("no", "failed")
    assert sp("· dot") == ("dot", "idle")
    assert sp("✔\U000e0100 x") == ("x", "done")
    assert sp("✔ ️ x") == ("️ x", "done")
    assert sp("  ✘ deploy ✔") == ("deploy ✔", "failed")


def test_store_sequence():
    stored, said = store(None, "⠂ Fix it")
    assert (stored, said) == ("⠂ Fix it", ("Fix it", "working"))
    stored, said = store(stored, "⠐ Fix it")
    assert (stored, said) == ("⠐ Fix it", None)
    stored, said = store(stored, "⠐ Fix it")
    assert (stored, said) == ("⠐ Fix it", None)
    stored, said = store(stored, "✳ Fix it")
    assert (stored, said) == ("✳ Fix it", ("Fix it", "idle"))
    stored, said = store(stored, "✳ Run tests")
    assert (stored, said) == ("✳ Run tests", ("Run tests", "idle"))
    assert store(None, "") == ("", None)
    assert store("x", "x ") == ("x ", None)


def test_shown_title():
    assert shown_title({"kind": "pty", "title": "⠂ Fix it"}) == ("Fix it", "working")
    assert shown_title({"kind": "remote-pty", "title": "✔ done"}) == ("done", "done")
    assert shown_title({"kind": "browser", "title": "● Slack | general"}) == ("● Slack | general", None)
    assert shown_title({"kind": "pty", "title": "⠂ raw", "title_text": "Given", "title_activity": "idle"}) == ("Given", "idle")
    assert shown_title({"kind": "pty", "title": "⠂ raw", "title_text": "Given", "title_activity": "busy"}) == ("Given", None)
    assert shown_title({"kind": "browser", "title": "x", "title_text": "", "title_activity": None}) == ("", None)
    assert shown_title({"kind": "pty"}) == ("", None)
