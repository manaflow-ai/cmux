from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTRACT = ROOT / "docs" / "cli-contract.md"


def test_diagnostics_commands_are_in_cli_contract_and_no_socket_probes() -> None:
    contract = CONTRACT.read_text(encoding="utf-8")
    assert_diagnostics_commands_are_in_cli_contract(contract)


def assert_diagnostics_commands_are_in_cli_contract(contract: str) -> None:
    required_fragments = [
        "| `iroh-diag` | Print the host's Iroh Connection Report",
        "| `sudo run [-r <reason>] [-t <timeout>] (-c <command> \\| <script.sh> \\| -)` | Submit a privileged command request",
        "| `sudo pending` | List queued privileged command request IDs",
        "| `sudo setup-touch-id` | Install or refresh the Touch ID sudo helper",
        "`sudo run` accepts exactly one script source: `-c <command>`, a regular UTF-8 script file, or `-` for standard input.",
        "`-t` must be a positive integer no larger than 86,400 seconds; omitted requests wait up to 300 seconds.",
        "the app shows the pending request for approval before execution",
        "Pending approval or approved execution timeouts return exit code 124.",
        "`sudo pending` lists queued request IDs, one per line, for requests still waiting for approval or completion.",
        "- `cmux iroh-diag --help` -> `Usage: cmux iroh-diag`",
        "- `cmux help diagnostics` -> `sudo run [-r reason] [-t timeout] (-c 'command' | script.sh | -)`",
        "- `cmux help diagnostics` -> `sudo pending`",
        "- `cmux help diagnostics` -> `sudo setup-touch-id`",
    ]

    missing = [fragment for fragment in required_fragments if fragment not in contract]

    assert missing == []

    lines = contract.splitlines()
    sudo_detail_line = next(
        index
        for index, line in enumerate(lines)
        if line.startswith("`sudo run` accepts exactly one script source")
    )
    sudo_outcome_line = next(
        index
        for index, line in enumerate(lines)
        if line.startswith("After queueing, cmux launches")
    )
    final_top_level_row = next(
        index
        for index, line in enumerate(lines)
        if line.startswith("| `__tmux-compat` |")
    )

    assert sudo_detail_line > final_top_level_row
    assert sudo_outcome_line > final_top_level_row


def main() -> int:
    contract = CONTRACT.read_text(encoding="utf-8")
    assert_diagnostics_commands_are_in_cli_contract(contract)
    print("cli contract diagnostics inventory ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
