Fix strict mode in `envexpand.py`, the variable expansion behind workspace configs and `.env` files.

Bug report: "We turned on strict expansion so a missing secret fails the launch instead of starting the agent with
an empty token. `expand('$API_TOKEN', env, strict=True)` raises as it should, but our config says
`--token=${API_TOKEN}` and that one quietly expands to `--token=` and the agent starts with no token."

Contract: with `strict=True`, an expansion raises `UnsetVariable` (with the variable's `name`) whenever the result
would need the value of a variable that is not set, whatever form references it, and wherever the text came from:
every function that takes `strict` applies it to all the text it expands (except what is documented as literal).
`${NAME:-word}` and `${NAME-word}` need NAME's value only when they do not use `word`, and need what `word`
references only when they do use it: a default that is not used is never evaluated. Without `strict` nothing
raises `UnsetVariable` and every result stays exactly as it is today.
