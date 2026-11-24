from rustdoc import doc


def test_brackets_escaped():
    # 98570c7fbad: the [::1] in a host list became an intra-doc link.
    assert doc("hosts: localhost, [::1], <hex> and `code`", "    ") == [
        "    /// hosts: localhost, \\[::1\\], \\<hex> and \\`code\\`"]


def test_backslashes_escape_once():
    assert doc(r"a \[::1\] path C:\x") == [r"/// a \\\[::1\\\] path C:\\x"]
    assert doc("\\") == ["/// \\\\"]
    assert doc("\\`") == ["/// \\\\\\`"]


def test_existing_behavior():
    assert doc("") == [] and doc(None) == []
    assert doc("  one\n\ttwo   three ") == ["/// one two three"]
    assert doc("a > b") == ["/// a > b"]
    assert doc(42) == ["/// 42"]

