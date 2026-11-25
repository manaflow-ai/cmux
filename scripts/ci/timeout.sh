#!/usr/bin/env bash
# timeout [--kill-after=DURATION] DURATION COMMAND [ARG...]: GNU timeout(1) for every CI host, a Mac included.
#
# Why (2026-11-11): macOS ships no `timeout`. scripts/ci/bun-install.sh called it bare, so tooling-tests passed on a
# Linux runner and failed on a Mac one ("timeout: command not found", exit 127) on whichever PR the placement sent
# there (#40892, #41288, #41299, #41305). Every scripts/ci shell script bounds a command through this file instead
# (tests/test_cmux_next_fast_gates.py's CiScriptsCallPortableTimeout fails on a bare `timeout` or `gtimeout`).
#
# Uses GNU `timeout`, then GNU `gtimeout` (Homebrew coreutils), then a perl watchdog with the same contract:
#   - COMMAND runs in its own process group; at DURATION the group gets TERM, and with --kill-after, KILL that long
#     after (so a child it started, a postinstall or a `sleep`, ends with it and cannot hold the log open);
#   - exit 124 when the deadline ended it, 137 (128+9) when the KILL did, else COMMAND's own status (128+N for
#     a signal N); 125 for bad arguments, 126/127 when COMMAND cannot run or is not found.
# DURATION: a number with an optional s, m, h or d suffix. 0 means no deadline, as in GNU timeout.
# CI_TIMEOUT_IMPL=perl forces the watchdog (the tests run it on Linux, so the Mac path is tested on every runner).
set -u

# A `timeout` on PATH that is a shim to this file (macos-cross-runtime-check.sh's) answers the probe below with
# nothing, instead of probing itself again without end.
[ -z "${CI_TIMEOUT_PROBING:-}" ] || exit 1
if [ "${CI_TIMEOUT_IMPL:-}" != perl ]; then
  # GNU only: Windows' timeout.exe and BusyBox's take other arguments.
  for candidate in timeout gtimeout; do
    if command -v "$candidate" >/dev/null 2>&1 \
      && CI_TIMEOUT_PROBING=1 "$candidate" --version 2>/dev/null | grep -q GNU; then
      exec "$candidate" "$@"
    fi
  done
fi

if ! command -v perl >/dev/null 2>&1; then
  echo "timeout: no GNU timeout, gtimeout or perl on $(uname -s) $(hostname); install coreutils or perl" >&2
  exit 125
fi
# `--`: the arguments are the script's (`--kill-after=15 ...`), not perl's own switches.
exec perl -e '
  use strict;
  use warnings;
  use POSIX ();
  use Time::HiRes ();

  sub seconds_of {
    my ($text) = @_;
    my %unit = (s => 1, m => 60, h => 3600, d => 86400);
    return undef unless defined $text && $text =~ /^(\d+(?:\.\d+)?|\.\d+)([smhd]?)$/;
    return $1 * $unit{$2 || "s"};
  }
  sub usage { print STDERR "timeout: $_[0]\nusage: timeout [--kill-after=DURATION] DURATION COMMAND [ARG...]\n"; exit 125 }

  my $kill_after = 0;
  while (@ARGV && $ARGV[0] =~ /^-/) {
    my $flag = shift @ARGV;
    if ($flag =~ /^--kill-after=(.*)$/ || $flag =~ /^-k(.+)$/) { $kill_after = seconds_of($1) // usage("invalid duration: $1") }
    elsif ($flag eq "--kill-after" || $flag eq "-k") { my $v = shift @ARGV; $kill_after = seconds_of($v) // usage("invalid duration") }
    elsif ($flag eq "--") { last }
    else { usage("unsupported option: $flag") }
  }
  my $text = shift @ARGV;
  my $limit = seconds_of($text) // usage(defined $text ? "invalid duration: $text" : "missing duration");
  usage("missing command") unless @ARGV;

  my $pid = fork() // do { print STDERR "timeout: fork: $!\n"; exit 125 };
  if ($pid == 0) {
    setpgrp(0, 0);
    { no warnings "exec"; exec { $ARGV[0] } @ARGV; }
    print STDERR "timeout: failed to run command \x27$ARGV[0]\x27: $!\n";
    POSIX::_exit($!{ENOENT} ? 127 : 126);
  }

  # A signal sent to this watchdog (the job cancelled, an outer deadline) goes to the command, as with GNU timeout.
  for my $name (qw(TERM INT HUP QUIT)) {
    $SIG{$name} = sub { kill $name, -$pid; kill $name, $pid };
  }
  my $timed_out = 0;
  my $killed = 0;
  $SIG{ALRM} = sub {
    if (!$timed_out) {
      $timed_out = 1;
      kill "TERM", -$pid; kill "TERM", $pid;
      Time::HiRes::alarm($kill_after) if $kill_after > 0;
    } else {
      $killed = 1;
      kill "KILL", -$pid; kill "KILL", $pid;
    }
  };
  Time::HiRes::alarm($limit) if $limit > 0;

  my $status;
  while (1) {
    my $done = waitpid($pid, 0);
    if ($done == $pid) { $status = $?; last }
    next if $!{EINTR};
    $status = 255 << 8; last;
  }
  Time::HiRes::alarm(0);

  exit 137 if $killed;
  exit 124 if $timed_out;
  exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
' -- "$@"
