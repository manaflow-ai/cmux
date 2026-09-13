"""Compatibility entrypoint for the renamed broken-pipe regression test."""

from test_cli_sigpipe_ignore import main


if __name__ == "__main__":
    raise SystemExit(main())
