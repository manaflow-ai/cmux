Implement `slugify(text: str, max_len: int = 50) -> str` in `slugify.py`. Steps: Unicode-normalize with NFKD and drop
combining marks (so `é` becomes `e`); lowercase; every run of characters that are not ASCII letters or digits becomes a
single `-`; strip leading and trailing `-`. Then, if longer than `max_len`, cut at the last `-` at or before `max_len`
so no word is split (if there is no such `-`, cut at exactly `max_len`), and strip a trailing `-`. Text that yields
nothing returns `"n-a"`. Raise ValueError when max_len < 1.
