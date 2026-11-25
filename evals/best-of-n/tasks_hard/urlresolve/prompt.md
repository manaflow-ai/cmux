Implement `resolve(base: str, ref: str) -> str` in `urlresolve.py`: RFC 3986 section 5.2 reference resolution,
strict mode, with no `urllib` or other URL library (string handling and `re` only).

- Split each URI with the RFC's appendix B regex into scheme, authority, path, query, fragment, keeping track of
  whether authority, query and fragment are present (an empty query `?` is different from no query).
- `base` is an absolute URI (has a scheme); raise ValueError if it has none.
- Follow 5.2.2 exactly, including: a ref with a scheme ignores the base (its path still gets dot-segment removal); a
  ref with an authority keeps it; an empty ref path keeps the base path and takes the ref's query if present, else
  the base's; a ref path starting with `/` is absolute; otherwise merge (5.2.3): if the base has an authority and an
  empty path, the result is `/` + ref path, else the base path up to and including its last `/` + ref path.
- Remove dot segments (5.2.4) exactly as the RFC's algorithm, including `..` above the root (dropped) and trailing
  `.`/`..` leaving a trailing `/`.
- Recompose per 5.3. The fragment always comes from the ref. Do not normalise case or percent-encoding.
