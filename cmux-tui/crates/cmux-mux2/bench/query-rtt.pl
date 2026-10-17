#!/usr/bin/perl
# query-rtt.pl N: runs inside a terminal. Sends N cursor-position reports
# (CSI 6 n) and N primary device attribute queries (CSI c), waits for each
# reply, checks it, and prints one JSON line with reply latency percentiles.
# A wrong or missing reply exits 1.
use strict; use warnings;
use Time::HiRes qw(time);
my $n = shift // 1000;
system('stty', 'raw', '-echo');
$| = 1;
sub ask { my ($q, $end) = @_;
    my $t = time; syswrite STDOUT, $q; my $r = '';
    while ($r !~ /$end/) { my $c; my $k = sysread STDIN, $c, 64; die "eof\n" unless $k; $r .= $c }
    return (time - $t, $r) }
my (@cpr, @da);
for my $i (1 .. $n) {
    my $row = 1 + $i % 20; my $col = 1 + $i % 70;
    syswrite STDOUT, "\e[$row;${col}H";
    my ($d, $r) = ask("\e[6n", qr/R/);
    if ($r !~ /\e\[$row;${col}R/) { system('stty', 'sane'); print "\r\nBAD-CPR $i got ", join(' ', map { sprintf '%02x', ord } split //, $r), "\r\n"; exit 1 }
    push @cpr, $d;
    ($d, $r) = ask("\e[c", qr/c/);
    if ($r !~ /\e\[\?[\d;]*c/) { system('stty', 'sane'); print "\r\nBAD-DA $i\r\n"; exit 1 }
    push @da, $d;
}
system('stty', 'sane');
sub p { my ($x, $f) = @_; my @s = sort { $a <=> $b } @$x; sprintf '%.1f', 1e6 * $s[int($f * $#s)] }
print "\e[2J\e[H";
printf qq({"query_rtt":%d,"cpr_p50_us":%s,"cpr_p99_us":%s,"da_p50_us":%s,"da_p99_us":%s}\n),
    $n, p(\@cpr, .5), p(\@cpr, .99), p(\@da, .5), p(\@da, .99);
