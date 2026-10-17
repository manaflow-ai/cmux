#!/usr/bin/perl
# gen-corpus.pl DIR: writes the mux2-verify corpus. Deterministic (fixed seeds).
#   plain.txt    256 MB of digits and spaces
#   sgr.txt      256 MB of words with 16-color SGR runs
#   unicode.txt  32 MB of CJK, emoji, combining marks and wraps, with SGR
#   cursor.txt   32 MB of cursor moves, erases, scroll regions, insert/delete,
#                alternate screen, tabs, save/restore, 256 and true color
use strict; use warnings;
my $dir = shift // die "usage: gen-corpus.pl DIR\n";
mkdir $dir;

sub gen { my ($name, $size, $seed, $line) = @_;
    srand($seed); open(my $f, '>:raw', "$dir/$name") or die "$name: $!";
    my $n = 0; while ($n < $size) { my $l = $line->(); print $f $l; $n += length $l } close $f }

my @words = map { join '', map { chr(97 + int rand 26) } 1 .. (2 + int rand 9) } 1 .. 5000;

gen('plain.txt', 256e6, 9, sub { join(' ', map { int rand 1e9 } 1 .. 10) . "\n" });
gen('sgr.txt', 256e6, 7, sub {
    join(' ', map { (rand() < .2 ? "\e[3" . int(rand 8) . 'm' : '') . $words[rand @words] . (rand() < .2 ? "\e[0m" : '') } 1 .. 12) . "\n" });

my @uni = ("\x{4e2d}", "\x{6587}", "\x{1F600}", "\x{1F680}", "e\x{301}", "a\x{308}", "\x{0915}\x{094D}\x{0937}",
           "\x{00e9}", "\x{03bb}", "\x{2500}", "\x{FF21}", "\x{1F1FA}\x{1F1F8}");
gen('unicode.txt', 32e6, 11, sub {
    my $s = join('', map { (rand() < .1 ? "\e[1;3" . int(rand 8) . 'm' : '') . (rand() < .5 ? $uni[rand @uni] : $words[rand @words] . ' ') } 1 .. (5 + int rand 60));
    utf8::encode($s); "$s\e[0m\n" });

gen('cursor.txt', 32e6, 13, sub {
    my $r = rand; my ($row, $col) = (1 + int rand 50, 1 + int rand 150);
    return "\e[$row;${col}H" . $words[rand @words] if $r < .15;
    return "\e[" . (1 + int rand 5) . (qw(A B C D))[rand 4] if $r < .25;
    return "\e[" . (int rand 3) . (qw(J K))[rand 2] if $r < .30;
    return "\e[" . (1 + int rand 10) . ';' . (20 + int rand 30) . "r" if $r < .33;
    return "\e[r" if $r < .35;
    return "\e[" . (1 + int rand 3) . (qw(L M @ P X))[rand 5] if $r < .40;
    return "\e[?1049h" if $r < .41;
    return "\e[?1049l" if $r < .42;
    return "\e7" if $r < .44;
    return "\e8" if $r < .46;
    return "\t" . $words[rand @words] if $r < .50;
    return "\e[38;5;" . int(rand 256) . 'm' if $r < .55;
    return "\e[48;2;" . join(';', map { int rand 256 } 1 .. 3) . 'm' if $r < .60;
    return "\e[0m\n" if $r < .70;
    return "\eM" if $r < .72;
    return "\eD" if $r < .74;
    return $words[rand @words] . ' ';
});
print "corpus written to $dir\n";
