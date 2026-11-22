title: Plain cmux is this app's CLI in every terminal
category: fixed
docs: https://cmux.com/docs/cli

Terminals that cmux starts for you, such as agent terminals and terminals from `cmux workspace new` or `cmux tab create terminal`, now run this app's own `cmux`, even when your shell setup or the agent's PATH lists an older `cmux` first. Commands like `cmux browser open` no longer fail with an unknown-action error from an old CLI.
