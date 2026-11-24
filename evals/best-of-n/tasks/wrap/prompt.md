Implement `wrap(text: str, width: int) -> list[str]` in `wrap.py`: greedy word wrap. Words are runs of non-whitespace;
any whitespace (spaces, tabs, newlines) separates words and is collapsed. Each line is words joined by one space and is
at most `width` characters. A word longer than `width` is split into chunks of exactly `width` characters (the last
chunk may be shorter), each chunk starting a new line, and the next word may join the last chunk's line if it fits.
Empty or whitespace-only text gives `[]`. Raise ValueError when width < 1.
