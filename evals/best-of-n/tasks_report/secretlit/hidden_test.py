# From cmux scripts/cmux-next/cloud-key-probe.py (fix db9ddfd2d3c, its cloud-journey test values), plus spec cases.
from secretlit import literal_secret as s, entropy


def test_the_commit_case_a_bracket_inside_a_key():
    assert s("ab+Zq8~Hw4[Kd9Lm2Px7]")
    assert s("9abQ[2xLm7Rt4Vw8Np3Z]")


def test_code_that_starts_as_a_call_or_index_is_not_a_key():
    for v in ["os.environ.get(KEY_NAME_1234)", "env[OPENAI_API_KEY_1]", "getKey(a1b2c3d4e5f6g7)",
              "_cfg.secrets[0123456789abc]", "loadSecret1234567890()"]:
        assert not s(v), v


def test_references_and_stand_ins():
    for v in ["$OPENAI_API_KEY_123456", "%APPDATA%a1b2c3d4e5f6", "{{secrets.KEY_12345678}}", "<your-key-here-123>",
              "@Microsoft.KeyVault(x1)", "*alias_1234567890abc", "your-api-key-1234567890", "sk-test-1234567890abcdef",
              "PLACEHOLDER_abcdef123456", "process.env.OPENAI_KEY_1", "environ.KEY_1234567890ab", "abc...xyz1234567890",
              "AKIAIOSFODNN7EXAMPLE", "Example123456789012"]:
        assert not s(v), v
    # A stand-in word only counts at the start (after at most a short prefix): a key may hold one by chance.
    assert s("Ab3QxtestKq2Zr9Lw4Np5")
    assert s("Ab3Qxfindings7Kq2Zr9Lw4Np5")
    assert s("getenvironment1234567890")  # not the whole word getenv


def test_token_alphabet_literals():
    assert s("sk-proj-a1B2c3D4e5F6g7H8")
    assert s("AIzaSyA1b2C3d4E5f6G7h8I9j0K")
    assert not s("short1234567")  # under 16
    assert not s("abcdefghijklmnop")  # no digit, low variety
    assert not s("a/123456789012345678")  # its only digits come after the first `/`... and too little variety
    assert s("abcdef1234567890/xyz")


def test_printable_needs_variety():
    assert s("Qd7,Kx2;Mn4)Lw9}Vb3Rz8")
    assert not s("useFoo:!0,bar:!1,baz:!2")  # minified code: low variety
    assert not s("aaaa!aaaa!1111!1111")


def test_no_digit_tokens_need_more_variety():
    assert s("qWeRtYuIoPaSdFgHjKlZxCvBnM")
    assert not s("requiredStringValueHere")
    assert not s("qWeRtYuIoPaSdFgHj")  # under 20


def test_entropy_is_kept():
    assert abs(entropy("abcd") - 2.0) < 1e-9
