Fix `tokenize2.py`, the escape-sequence tokenizer that sits between the PTY reader and the terminal screen.

Bug reports:
1. "Pasting a big image with an inline-image escape (or copying a large buffer over OSC 52) freezes the pane for
   tens of seconds. The PTY delivers it in 4 KB reads."
2. "Hyperlinks (OSC 8) sometimes swallow the text after them when output is slow, but `cat` of the same file is
   fine."

Contract: the rules in the module docstring stand as written. For any way of cutting a byte stream into chunks,
the tokens from all `feed` calls followed by `flush()`, with adjacent text tokens joined and empty text tokens
dropped, equal what `tokenize` returns for the whole stream at once. `feed` still returns text as soon as it has
it. The total cost of feeding a stream is linear in its length however it is chunked: an 8 MB OSC fed in 4 KB
chunks must tokenize in well under 1 s.
