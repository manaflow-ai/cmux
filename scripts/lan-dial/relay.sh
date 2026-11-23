#!/bin/sh
# lan-dial relay: one connection of the lan-dial protocol (scripts/lan-dial/README.md).
#
# launchd starts this for each connection on the relay's Unix socket (inetdCompatibility, Wait false), with the
# accepted socket as stdin and stdout. The caller sends one line, `CONNECT HOST PORT`; the relay answers `OK` and
# becomes Apple's /usr/bin/nc to HOST:PORT, or answers `ERR <why>` and closes. After `OK`, every byte is the TCP
# stream's, both ways.
#
# Why /bin/sh and /usr/bin/nc: macOS Local Network privacy keeps a launchd- or runner-started third-party program
# (Homebrew or uv Python, Rust, Go, a CI runner and everything under it) off the LAN, but a launchd job rooted on
# Apple's /bin/sh may start /usr/bin/nc, and nc's connection is let through (measured on macOS 27.0.1,
# 2026-11-23). The job is launchd's own child, not the caller's, so the caller's process tree does not matter.
#
# The socket is mode 0600 and the job runs as the socket's owner, so the relay gives a caller nothing it could not
# do itself by loading its own launchd job.

nc_bin="${LAN_DIAL_NC:-/usr/bin/nc}"
# macOS nc: -G is the connect timeout in seconds. Tests on Linux set LAN_DIAL_NC_FLAGS to "".
nc_flags="${LAN_DIAL_NC_FLAGS--G 10}"

# `read` takes one byte at a time from a socket, so nothing past the newline is consumed.
IFS= read -r line || exit 0
line=$(printf '%s' "$line" | tr -d '\r')
set -f
# shellcheck disable=SC2086 # split the request line into its words
set -- $line
if [ "$#" -ne 3 ] || [ "$1" != CONNECT ]; then
  echo "ERR expected one line: CONNECT HOST PORT"
  exit 0
fi
host=$2
port=$3
case $host in
  '' | -* | *[!A-Za-z0-9.:%_-]*) echo "ERR not a host name or address: $host"; exit 0 ;;
esac
case $port in
  '' | *[!0-9]* | 0*) echo "ERR not a port: $port"; exit 0 ;;
esac
if [ "${#port}" -gt 5 ] || [ "$port" -gt 65535 ]; then
  echo "ERR not a port: $port"
  exit 0
fi
echo OK
# shellcheck disable=SC2086 # nc_flags is zero or more words
exec "$nc_bin" $nc_flags "$host" "$port"
