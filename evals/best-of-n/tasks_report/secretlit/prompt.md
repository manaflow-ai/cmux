# Key probe misses a real key that has a bracket in it

The machine key probe did not report my Perplexity key. The file has
`PERPLEXITY_API_KEY="ab+Zq8~Hw4[Kd9Lm2Px7]"` (rotated since), and `literal_secret` in `secretlit.py` says False for
that value. It looks like any value with a bracket in it is taken for code.

Code in that place really does look like `os.environ.get(...)`, `env[...]` or `getKey(...)`, and those must still not
be reported, nor anything else it skips today on purpose (references, stand-ins, documented example keys).
