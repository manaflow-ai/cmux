# Ported from acpmux server/chats/team_audit.rs a_saved_csv_opens_formulas_as_text (cmux 8c14cae03c5), plus spec cases.
from csvdefuse import defuse_formulas as d


def test_the_commit_case():
    body = ('person,title,cost,note\r\n'
            'alice,=HYPERLINK("http://x"),-12.5,ok\r\n'
            'bob,"=1+1, ""quoted""",3,@SUM(A1)\r\n'
            'carol,-2+3,"\r=x",\tlead\n'
            'dave,,"plain, text",+cmd|\' /C calc\'!A0\n'
            'eve,"multi\nline",7,')
    want = ('person,title,cost,note\r\n'
            'alice,\'=HYPERLINK("http://x"),-12.5,ok\r\n'
            'bob,"\'=1+1, ""quoted""",3,\'@SUM(A1)\r\n'
            'carol,\'-2+3,"\'\r=x",\'\tlead\n'
            'dave,,"plain, text",\'+cmd|\' /C calc\'!A0\n'
            'eve,"multi\nline",7,')
    assert d(body) == want


def test_nothing_risky_is_the_same_string():
    for plain in ['a,b\n"x, y",-1\n', "", "x", ",,,\n\n", '"",""\r\n', "1,2,-3.25\n"]:
        assert d(plain) == plain


def test_numbers_and_not_numbers():
    assert d("-") == "'-"
    assert d("+") == "'+"
    assert d("-0.0,10,-12.5") == "-0.0,10,-12.5"
    assert d("-x,+y") == "'-x,'+y"


def test_quoted_cells():
    assert d('"-12.5"') == '"-12.5"'
    assert d('"-x"') == '"\'-x"'
    assert d('"@a","=b"\n') == '"\'@a","\'=b"\n'
    assert d('"\tx"') == '"\'\tx"'
    assert d('a,"x\n=y"') == 'a,"x\n=y"'  # a formula char after a line break inside a quoted cell is not its first
    assert d('"a ""q"" b",=c') == '"a ""q"" b",\'=c'


def test_risky_chars_mid_cell_or_after_space_stay():
    assert d("a=b,x@y,1+1") == "a=b,x@y,1+1"


def test_row_starts():
    assert d("=a\n=b\r\n@c") == "'=a\n'=b\r\n'@c"
