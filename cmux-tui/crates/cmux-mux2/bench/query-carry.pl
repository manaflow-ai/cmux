#!/usr/bin/perl
# query-carry.pl: writes the start of a CPR query, waits for one input byte
# (the harness reads the screen in between, which parses the carried start),
# then writes the final byte. The reply must arrive at once.
# Prints QUERY-CARRY-OK or QUERY-CARRY-LATE.
use strict; use warnings; use Time::HiRes qw(time);
system('stty', 'raw', '-echo'); $| = 1;
syswrite STDOUT, "\e[6";
my $go; sysread STDIN, $go, 1;
my $t = time; syswrite STDOUT, "n";
my $r = ''; my $rin = ''; vec($rin, 0, 1) = 1;
while ($r !~ /R/) { my $rout = $rin; last unless select($rout, undef, undef, 0.5); my $c; sysread STDIN, $c, 64; $r .= $c }
my $ms = 1000 * (time - $t); system('stty', 'sane');
printf "\r\n%s %.2f ms\r\n", ($r =~ /\e\[\d+;\d+R/ ? 'QUERY-CARRY-OK' : 'QUERY-CARRY-LATE'), $ms;
