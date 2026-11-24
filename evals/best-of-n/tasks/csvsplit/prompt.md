Implement `split_csv_line(line: str) -> list[str]` in `csvsplit.py` for one RFC 4180 record (no newlines inside).
Fields are separated by commas. A field may be quoted with double quotes; inside a quoted field a comma is literal and
`""` is one literal quote. Unquoted fields are taken verbatim (spaces kept). An empty line is one empty field; a
trailing comma yields a trailing empty field. Raise ValueError for an unterminated quote, text after a closing quote
before the next comma (`"a"b`), or a quote inside an unquoted field (`a"b`). Do not use the csv module.
