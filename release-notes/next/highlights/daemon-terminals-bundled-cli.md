title: Plain cmux is this app's CLI in every terminal
category: fixed
docs: https://cmux.com/docs/api

Terminals that cmux starts for you, such as agent terminals, now run this app's own `cmux` even when your PATH lists an older one first. Commands like `cmux browser open` no longer fail with an unknown-action error.
