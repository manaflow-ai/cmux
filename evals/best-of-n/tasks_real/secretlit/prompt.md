Fix `literal_secret` in `secretlit.py`. A machine's key probe scans files for API keys: when a file names a key
(`PERPLEXITY_API_KEY=...`), `literal_secret(value)` says whether the value written after the name looks like the key
itself rather than code, a reference or a stand-in.

Bug report (from cmux commit db9ddfd2d3c, "brackets inside a key"): a real key with a bracket inside it,
`PERPLEXITY_API_KEY="ab+Zq8~Hw4[Kd9Lm2Px7]"`, was never reported: any `(` or `[` anywhere in the value made it read
as code. Only a value that *starts* as a call or an index is code (`os.environ.get(`, `env[`, `getKey(`); a bracket
elsewhere is a character like any other.

`literal_secret(value: str) -> bool`, in this order:

1. False when the value is one of `PUBLIC_VALUES`, or is a stand-in, or is not a literal.
   - A stand-in starts with one of the words placeholder, example, dummy, fake, test, stub, changeme, your, xxxx (any
     case), optionally after a prefix of 1 to 8 ASCII letters and a `-` or `_` (`your-key`, `sk-test-1`); or starts
     with `process.env`, `os.environ`, `environ` or `getenv` as a whole word; or contains `...` anywhere.
   - Not a literal: it starts with `$`, `%`, `{`, `<`, `@` or `*` (a reference), or it starts as code: an identifier
     (an ASCII letter or `_`, then ASCII letters, digits, `_` or `.`) immediately followed by `(` or `[`.
2. True when it is at least 16 characters of the token alphabet (ASCII letters, digits, `_ - . + / = :`) with at least
   one ASCII letter and at least one digit before its first `/` (a value with no `/` just needs a digit anywhere).
3. True when it is at least 16 printable ASCII characters other than space, `"`, `'`, backquote and backslash, with a
   letter and a digit, and its entropy (`entropy(value)`, bits per character) is at least 4.0.
4. True when it is at least 20 characters of the token alphabet with entropy at least 4.2; else False.

Keep the module's other names (`PUBLIC_VALUES`, `entropy`, the patterns) importable.
