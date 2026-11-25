from focusorder import TabStrip


def two_groups():
    s = TabStrip()
    for t in ("a", "b", "logs"):
        s.open("one", t)
    for t in ("mail", "chat", "x", "y"):
        s.open("two", t)
    s.pin("mail")
    s.pin("chat")
    return s


def test_reported_move_to_front_of_pinned_group():
    s = two_groups()
    assert s.order("two") == ["mail", "chat", "x", "y"]
    s.move("logs", "two", 0)
    assert s.order("two") == ["mail", "chat", "logs", "x", "y"]
    assert not s.pinned("logs")
    assert s.active("two") == "logs" and s.group_of("logs") == "two"


def test_move_pinned_tab_past_pinned_section():
    s = two_groups()
    s.pin("a")
    s.move("a", "two", 4)
    assert s.order("two") == ["mail", "chat", "a", "x", "y"]
    assert s.pinned("a")
    s.move("mail", "two", 99)
    assert s.order("two") == ["chat", "a", "mail", "x", "y"]


def test_move_within_group_to_valid_spot():
    s = two_groups()
    s.move("y", "two", 2)
    assert s.order("two") == ["mail", "chat", "y", "x"]
    s.move("chat", "two", 0)
    assert s.order("two") == ["chat", "mail", "y", "x"]


def test_open_after_pinned_tab_goes_after_pinned_section():
    s = two_groups()
    s.open("two", "new", after="mail")
    assert s.order("two") == ["mail", "chat", "new", "x", "y"]
    s.open("two", "n2", after="x")
    assert s.order("two") == ["mail", "chat", "new", "x", "n2", "y"]
    assert s.active("two") == "n2"


def test_reopen_respects_pinned_rule_and_state():
    s = two_groups()
    s.close("x")                      # x was at 2
    s.pin("y")                        # mail chat y
    assert s.reopen() == "x"
    assert s.order("two") == ["mail", "chat", "y", "x"]
    assert not s.pinned("x") and s.active("two") == "x"
    s.close("mail")                   # pinned, at 0
    s.pin("chat", False)
    s.pin("y", False)                 # no pinned tabs left
    assert s.reopen() == "mail"
    assert s.order("two")[0] == "mail" and s.pinned("mail")
    s.close("b")
    s.close("a")
    assert s.reopen() == "a" and s.reopen() == "b"
    assert s.order("one") == ["a", "b", "logs"]
    assert s.reopen() is None


def test_reopen_pinned_tab_clamped_to_pinned_section():
    s = TabStrip()
    for t in ("p", "q", "r", "s"):
        s.open("g", t)
    s.pin("p")
    s.pin("q")
    s.pin("r")                        # p q r | s
    s.close("r")                      # index 2
    s.pin("p", False)                 # q | p s
    assert s.reopen() == "r"
    assert s.order("g") == ["q", "r", "p", "s"] and s.pinned("r")


def test_close_active_goes_back_to_previous_in_group():
    s = two_groups()
    s.activate("x")
    s.activate("chat")
    s.close("chat")
    assert s.active("two") == "x"
    s.close("y")                      # not active: focus stays
    assert s.active("two") == "x"


def test_tab_moved_away_is_not_reactivated_in_old_group():
    s = two_groups()
    s.activate("a")
    s.activate("logs")
    s.activate("b")                   # one: history a, logs, b
    s.move("logs", "two", 10)
    assert s.active("one") == "b" and s.active("two") == "logs"
    s.close("b")
    assert s.active("one") == "a"
    assert s.active("two") == "logs"


def test_moving_active_tab_refocuses_source_group():
    s = two_groups()
    s.activate("a")
    s.activate("logs")                # one: active logs, previous a
    s.move("logs", "two", 2)
    assert s.active("one") == "a"
    s.move("a", "two", 2)
    assert s.active("one") == "b"
    s.move("b", "two", 2)
    assert s.active("one") is None and s.order("one") == []


def test_non_active_tab_leaving_keeps_focus():
    s = TabStrip()
    for t in ("a", "b", "c"):
        s.open("g", t)
    s.close("a")
    s.close("b")
    assert s.active("g") == "c"
    s.open("g", "d")
    s.move("c", "h", 0)
    assert s.active("g") == "d" and s.active("h") == "c"
