#!/bin/zsh
# query-gate.sh: the unwatched-path query tests, on a fresh server (the carry
# test waits on the server-wide byte count, so it must run first).
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
M=~/mux2/bin/mux2
$M stop 2>/dev/null
id=$($M new -- /usr/bin/perl ~/mux2/query-carry.pl)
until $M stats | grep -q 'bytes_in	[1-9]'; do :; done
$M screen $id >/dev/null; $M write $id x; $M wait $id >/dev/null; $M screen $id | grep QUERY-CARRY
id=$($M new -- /usr/bin/perl ~/mux2/query-edge.pl); $M wait $id >/dev/null; $M screen $id | grep QUERY-EDGE
$M stop
