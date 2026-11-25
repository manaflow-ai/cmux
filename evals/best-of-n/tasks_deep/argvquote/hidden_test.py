import shlex

from pytest_shim import raises
from argvquote import command_line, env_prefix, join, quote, split, ssh_argv

TRICKY = ["", "it's", "'", "''", "a b", 'say "hi"', "$HOME", "back\\slash", "tab\there", "new\nline", "*.py",
          "-m", "\\'", "'\"'", "end\\", "ünï"]


def test_reported_empty_argument_survives():
    argv = ["git", "commit", "--allow-empty", "-m", ""]
    assert shlex.split(join(argv)) == argv
    assert split(join(argv)) == argv


def test_quote_leaves_safe_words_alone():
    for word in ("git", "a/b.c", "user@host:22", "x=1,y=2", "--flag", "50%", "a+b"):
        assert quote(word) == word


def test_every_tricky_string_round_trips_through_sh():
    for s in TRICKY:
        assert shlex.split(quote(s)) == [s], s
    assert shlex.split(join(TRICKY)) == TRICKY


def test_split_reads_back_join():
    assert split(join(TRICKY)) == TRICKY
    for s in TRICKY:
        assert split(quote(s)) == [s], s


def test_split_empty_quoted_words():
    assert split("a '' b") == ["a", "", "b"]
    assert split('a "" b') == ["a", "", "b"]
    assert split("''") == [""]
    assert split("  ") == []


def test_split_matches_sh_on_backslashes_in_double_quotes():
    for line in (r'"a\b"', r'"a\\b"', r'"\"q\""', r'"c:\temp\new"', r'x"\n"y', r"a\ b", r"\'"):
        assert split(line) == shlex.split(line, posix=True), line
    assert split(r'"\$x \`y\`"') == ["$x `y`"]


def test_split_regressions():
    assert split("a'b'\"c\"d") == ["abcd"]
    assert split("  one\ttwo\nthree  ") == ["one", "two", "three"]
    assert split("echo 'a  b'") == ["echo", "a  b"]
    assert split("a\\\nb") == ["ab"]
    raises(ValueError, split, "'open")
    raises(ValueError, split, '"open')
    raises(ValueError, split, "trailing\\")


def test_command_line_and_env():
    line = command_line(["printf", "%s\n", "it's"], env={"MSG": "", "NAME": "o'neil"}, cwd="/tmp/my dir")
    words = shlex.split(line)
    assert words[:4] == ["cd", "/tmp/my dir", "&&", "MSG="]
    assert words[4:] == ["NAME=o'neil", "printf", "%s\n", "it's"]
    assert shlex.split(env_prefix({"A": "x y", "B": ""})) == ["A=x y", "B="]
    raises(ValueError, env_prefix, {"1BAD": "x"})


def test_ssh_remote_line_round_trips():
    argv = ["grep", "-r", "", "it's here"]
    out = ssh_argv("box", argv)
    assert out[:4] == ["ssh", "-t", "box", "--"]
    assert shlex.split(out[4]) == argv
