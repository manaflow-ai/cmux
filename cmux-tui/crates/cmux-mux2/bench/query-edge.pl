#!/usr/bin/perl
# query-edge.pl: a CSI cut by ESC, then a query, must be answered at once
# while no viewer watches. Prints QUERY-EDGE-OK or QUERY-EDGE-LATE.
use strict; use warnings; use Time::HiRes qw(time);
system('stty', 'raw', '-echo'); $| = 1;
my $t = time; syswrite STDOUT, "\e[1\e[6n";
my $r = ''; my $rin = ''; vec($rin, 0, 1) = 1;
while ($r !~ /R/) { my $rout = $rin; last unless select($rout, undef, undef, 0.5); my $c; sysread STDIN, $c, 64; $r .= $c }
my $ms = 1000 * (time - $t); system('stty', 'sane');
printf "\r\n%s %.2f ms\r\n", ($r =~ /\e\[\d+;\d+R/ ? 'QUERY-EDGE-OK' : 'QUERY-EDGE-LATE'), $ms;
