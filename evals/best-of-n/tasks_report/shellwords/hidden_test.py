from shellwords import split_command as s
import pytest_shim as t


def test_plain():
    assert s("gh pr list") == ([], ["gh", "pr", "list"])
    assert s("X=1 Y=2 gh") == (["X=1", "Y=2"], ["gh"])
    assert s("X=1") == (["X=1"], [])
    assert s("") == ([], []) and s("  \t\n ") == ([], [])
    assert s("gh X=1") == ([], ["gh", "X=1"])


def test_quoted_assignment_is_the_program():
    # c3d4bcc07c4: "X=1" cmd runs X=1.
    assert s('"X=1" gh') == ([], ["X=1", "gh"])
    assert s("'X=1' gh") == ([], ["X=1", "gh"])
    assert s('X"=1" gh') == ([], ["X=1", "gh"])
    assert s("X\\=1 gh") == ([], ["X=1", "gh"])
    assert s("\\X=1 gh") == ([], ["X=1", "gh"])
    assert s("''X=1 gh") == ([], ["X=1", "gh"])
    assert s('X"+"=1 gh') == ([], ["X+=1", "gh"])
    assert s("A=1 'B=2' C=3 gh") == (["A=1"], ["B=2", "C=3", "gh"])


def test_quoted_values_are_fine():
    assert s('X="a b" gh') == (["X=a b"], ["gh"])
    assert s("X='$HOME' gh") == (["X=$HOME"], ["gh"])
    assert s('X=a"b c"d e') == (["X=ab cd"], ["e"])
    assert s("X=1'' gh") == (["X=1"], ["gh"])
    assert s("X=\\ a gh") == (["X= a"], ["gh"])
    assert s("X= gh") == (["X="], ["gh"])


def test_appends_and_subscripts():
    assert s("X+=1 gh") == (["X+=1"], ["gh"])
    assert s("X[0]=1 gh") == (["X[0]=1"], ["gh"])
    assert s("X[i]+=v gh") == (["X[i]+=v"], ["gh"])
    assert s("X[0]\\=1 gh") == ([], ["X[0]=1", "gh"])


def test_names():
    assert s("1X=2 gh") == ([], ["1X=2", "gh"])
    assert s("_x9=2 gh") == (["_x9=2"], ["gh"])
    assert s("=1 gh") == ([], ["=1", "gh"])
    assert s("X-Y=1 gh") == ([], ["X-Y=1", "gh"])
    assert s("X+1=2 gh") == ([], ["X+1=2", "gh"])


def test_quoting_rules():
    assert s("echo 'a b'\"c d\"e") == ([], ["echo", "a bc de"])
    assert s("echo '\\n' \\n") == ([], ["echo", "\\n", "n"])
    assert s("echo '' \"\"") == ([], ["echo", "", ""])
    assert s("echo $X * ~") == ([], ["echo", "$X", "*", "~"])
    assert s("echo a#b #c") == ([], ["echo", "a#b", "#c"])


def test_errors():
    for bad in ["echo 'a", 'echo "a', "echo a\\", 'X="1 gh']:
        t.raises(ValueError, s, bad)
