import math
import re

# Values a provider documents as examples: never a finding.
PUBLIC_VALUES = frozenset({"AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"})
SECRET_LITERAL = re.compile(r"^(?=[^/]*[0-9])(?=.*[A-Za-z])[A-Za-z0-9_\-.+/=:]{16,}$")
SECRET_TOKEN = re.compile(r"^[A-Za-z0-9_\-.+/=:]{16,}$")
SECRET_PRINTABLE = re.compile(r"^(?=.*[0-9])(?=.*[A-Za-z])[!#-&(-\[\]-_a-~]{16,}$")
NOT_LITERAL = re.compile(r"^[$%{<@*]|[(\[]")
STAND_IN = re.compile(
    r"^(?:[A-Za-z]{1,8}[-_])?(?:placeholder|example|dummy|fake|test|stub|changeme|your|xxxx)"
    r"|^(?:process\.env|os\.environ|environ|getenv)\b|\.\.\.",
    re.I,
)


def entropy(value):
    """Bits per character: a random key is near log2 of its alphabet, a word or identifier far below."""
    counts = {}
    for c in value:
        counts[c] = counts.get(c, 0) + 1
    return -sum(n / len(value) * math.log2(n / len(value)) for n in counts.values())


def literal_secret(value):
    """Whether a value written after a key's name in a file looks like the key itself."""
    if value in PUBLIC_VALUES or STAND_IN.search(value) or NOT_LITERAL.search(value):
        return False
    if SECRET_LITERAL.match(value):
        return True
    if SECRET_PRINTABLE.match(value) and entropy(value) >= 4.0:
        return True
    return bool(SECRET_TOKEN.match(value)) and len(value) >= 20 and entropy(value) >= 4.2
