# Remote spin-up selftest

`acpmux machine selftest` runs the unattended remote setup scenario used by
the fleet check. It always prints one JSON object containing a `steps` table;
the process exits non-zero when a command fails or either budget is exceeded.

The scenario is deliberately a tab-separated adapter rather than a second
provider implementation in Rust. Each non-comment line is:

```text
step-name<TAB>person-equivalent-actions<TAB>command
```

Commands run in order with `CMUX_SELFTEST_STEP` set to the step name. A fleet
driver can therefore use the same command on a Linux VM (CLI join) and on an
owned fleet Mac (GUI actions through `cmux action run`). Keep credentials in
the driver environment; they never become command-line arguments or report
fields. The JSON row contains only the step, action count, elapsed seconds,
and a bounded error string.

Example:

```sh
cat >"$RUNNER_TEMP/remote-selftest.tsv" <<'EOF'
door-a-cli	1	./fleet-driver join-linux-over-ssh
door-a-gui	1	cmux action run --fleet-host "$LEASED_MAC" remote.join --queue-prompt
first-reply	0	./fleet-driver chat-first-reply
drop-10s	1	./fleet-driver drop-link 10
drop-60s	1	./fleet-driver drop-link 60
remove	1	./fleet-driver remove
EOF
acpmux machine selftest --scenario "$RUNNER_TEMP/remote-selftest.tsv" \
  --max-actions 2 --max-seconds 30
```

Both Door A rows are mandatory. The GUI row must use a leased owned fleet Mac
(`cmux-ci lease take ... --for 1h`) and drive the machine menu's **Yours** row;
the queued prompt during setup is part of that step. A missing or failing Door
A row fails the run. No GUI automation runs on cmux16, Blacksmith, or a
developer Mac.
