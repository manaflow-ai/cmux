#!/usr/bin/perl
# query-edge.pl: queries the batch scanner must recognize while no viewer
# watches: a CSI cut by ESC, a C0 control and DEL inside the sequence. Each
# must be answered at once. Prints QUERY-EDGE-OK or QUERY-EDGE-LATE per case.
use strict; use warnings; use Time::HiRes qw(time);
system('stty', 'raw', '-echo'); $| = 1;
my @cases = (["cut-csi", "\e[1\e[6n"], ["esc-bel", "\e\a[6n"], ["csi-del", "\e[6\x7fn"]);
my @out;
for my $c (@cases) {
    my $t = time; syswrite STDOUT, $c->[1];
    my $r = ''; my $rin = ''; vec($rin, 0, 1) = 1;
    while ($r !~ /R/) { my $rout = $rin; last unless select($rout, undef, undef, 0.5); my $b; sysread STDIN, $b, 64; $r .= $b }
    push @out, sprintf("%s %s %.2f ms", ($r =~ /\e\[\d+;\d+R/ ? 'QUERY-EDGE-OK' : 'QUERY-EDGE-LATE'), $c->[0], 1000 * (time - $t));
}
system('stty', 'sane');
print "\r\n", join("\r\n", @out), "\r\n";
