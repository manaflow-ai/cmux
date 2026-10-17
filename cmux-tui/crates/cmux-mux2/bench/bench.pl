#!/usr/bin/perl
# Rex vs cmux-tui benchmark. Runs on the target Mac with system perl only.
#   bench.pl scale {rex|cmux} MAX [--shell]    create terminals until MAX or refusal
#   bench.pl tput  {rex|cmux} FILE [--attach]  time cat FILE through one terminal
#   bench.pl rtt   {rex|cmux} N                CLI write -> screen round trips
# Every result is one JSON line on stdout.
use strict; use warnings;
use Time::HiRes qw(time sleep);
use JSON::PP; use File::Basename;
$| = 1;
my $REX = "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex";
my $CMUX = "$ENV{HOME}/rex-bench/cmux-tui";
my $MUX2 = "$ENV{HOME}/mux2/bin/mux2";
my @SLEEP = ("/bin/sleep", "1000000");
my $J = JSON::PP->new->canonical;

sub run_cmd {    # returns (rc, stdout+stderr)
    my @argv = @_;
    my $pid = open(my $fh, "-|") // die "fork: $!";
    if (!$pid) { open(STDERR, ">&STDOUT"); exec { $argv[0] } @argv; exit 127 }
    local $/; my $out = <$fh> // ""; close $fh;
    return ($? >> 8, $out);
}
sub must { my ($rc, $o) = run_cmd(@_); die "rc=$rc @_[0..3]: $o" if $rc; $o }
sub emit { print $J->encode($_[0]), "\n" }
sub pct { my ($xs, $f) = @_; my @s = sort { $a <=> $b } @$xs; sprintf("%.1f", 1000 * $s[int($f * $#s)]) + 0 }

sub cpu_s { my $t = shift; my $d = 0; ($d, $t) = ($1, $2) if $t =~ /^(\d+)-(.*)$/;
    my $s = 0; $s = $s * 60 + $_ for split /:/, $t; $s + 86400 * $d }

sub server_pid {
    my $pat = $_[0] eq "rex" ? "rex server run" : $_[0] eq "mux2" ? "mux2/bin/mux2d" : "cmux-tui daemon start --session bench";
    my (undef, $o) = run_cmd("/usr/bin/pgrep", "-f", $pat);
    my @p = sort { $a <=> $b } grep { /^\d+$/ } split /\s+/, $o; $p[0];
}

sub footprint {
    my $kind = shift; my $root = server_pid($kind);
    my (%row, %kids);
    for (split /\n/, must("/bin/ps", "-axo", "pid=,ppid=,rss=,time=,comm=")) {
        my ($pid, $ppid, $rss, $cpu, $comm) = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/ or next;
        $row{$pid} = [$ppid, $rss, $cpu, $comm]; push @{ $kids{$ppid} }, $pid;
    }
    my @all; my @stack = ($root);
    while (@stack) { my $p = pop @stack; next unless $row{$p}; push @all, $p; push @stack, @{ $kids{$p} || [] } }
    my @helpers = grep { $_ != $root && basename($row{$_}[3]) !~ /^(sleep|cat)$/ } @all;
    my %kinds = map { basename($row{$_}[3]) => 1 } @helpers;
    my (undef, $lsof) = run_cmd("/usr/sbin/lsof", "-p", $root);
    my $hr = 0; $hr += $row{$_}[1] for @helpers;
    return { server_rss_kb => $row{$root}[1] + 0, server_cpu_s => cpu_s($row{$root}[2]),
             helper_procs => scalar(@helpers), helper_rss_kb => $hr, helper_kinds => [sort keys %kinds],
             all_procs => scalar(@all), open_fds => (split /\n/, $lsof) - 1 };
}

sub vm_used_mb {
    my $o = must("/usr/bin/vm_stat"); my ($pg) = $o =~ /page size of (\d+)/; my $u = 0;
    $u += $1 while $o =~ /Pages (?:active|wired down|occupied by compressor):\s+(\d+)/g;
    int($u * $pg / 1048576);
}

sub idle_cpu { my ($k, $sec) = @_; my $a = footprint($k)->{server_cpu_s}; sleep $sec;
    sprintf("%.2f", 100 * (footprint($k)->{server_cpu_s} - $a) / $sec) + 0 }

sub create_argv {
    my ($kind, $label, $shell) = @_;
    return ($REX, "--autostart=false", "new", $label, "--json", ($shell ? () : ("--shell=none", "--", @SLEEP)))
        if $kind eq "rex";
    return ($MUX2, "new", "--size", "80x24", ($shell ? () : ("--", @SLEEP))) if $kind eq "mux2";
    return ($CMUX, "--session", "bench", "--json", "workspace", "create", "--name", $label, ($shell ? () : ("--", @SLEEP)));
}

sub scale {
    my ($kind, $max, $shell) = @_;
    my %cp = map { $_ => 1 } (1, 10, 25, 50, 64, 65, 100, 128, 200, 250, 300, 400, 500, 750, 1000, 1500, 2000);
    my @lat; my $base = vm_used_mb();
    for my $i (1 .. $max) {
        my $t = time; my ($rc, $o) = run_cmd(create_argv($kind, "b$i", $shell)); my $dt = time - $t;
        if ($rc) { emit({ test => "scale", kind => $kind, shell => $shell ? \1 : \0, event => "refused", at => $i,
                          error => substr($o, 0, 400) }); last }
        push @lat, $dt;
        if ($cp{$i} || $i == $max) {
            sleep 1; my $fp = footprint($kind);
            my %r = (test => "scale", kind => $kind, shell => $shell ? \1 : \0, n => $i,
                     create_ms_p50 => pct(\@lat, .5), create_ms_p95 => pct(\@lat, .95),
                     system_used_mb_delta => vm_used_mb() - $base, %$fp);
            $r{server_idle_cpu_pct} = idle_cpu($kind, 10) if $i == 50 || $i == 200 || $i == 500 || $i == $max;
            emit(\%r);
        }
    }
    emit({ test => "scale", kind => $kind, shell => $shell ? \1 : \0, event => "done", created => scalar(@lat) });
}

sub tput {
    # The cat terminal starts first and waits for one line, so an attached
    # client watches exactly that terminal. The clock starts at the line.
    my ($kind, $path, $attach) = @_;
    my $size = -s $path; my $label = "tp" . int(rand(1e6)); my $att; my $dt;
    my @prog = ("/bin/sh", "-c", "read go; exec /bin/cat '$path'");
    my @viewer; my ($go, $done);
    if ($kind eq "mux2") {
        my $id = must($MUX2, "new", "--size", "200x50", "--", @prog); chomp $id;
        @viewer = ($MUX2, "attach", $id);
        $go = sub { must($MUX2, "write", $id, "\n") };
        $done = sub { must($MUX2, "wait", $id) };
    } elsif ($kind eq "rex") {
        my $o = must($REX, "--autostart=false", "new", $label, "--shell=none", "--keep-open", "--json", "--", @prog);
        my ($block) = $o =~ /"(block:[0-9a-f-]+)"/;
        @viewer = ($REX, "--autostart=false", "attach", $label);
        $go = sub { must($REX, "--autostart=false", "send", "-s", $label, "-b", $block, "\n") };
        $done = sub { must($REX, "--autostart=false", "wait", "-s", $label, $block) };
    } else {
        my $term = $J->decode(must($CMUX, "--session", "bench", "--json", "workspace", "create", "--name", $label,
                                   "--", @prog))->{value}{terminal_id};
        @viewer = ($CMUX, "attach", "--session", "bench", "--terminal", $term);
        $go = sub { must($CMUX, "--session", "bench", "terminal", $term, "write", "--text", "\n") };
        $done = sub { must($CMUX, "--session", "bench", "terminal", $term, "process", "wait", "--timeout-ms", "900000") };
    }
    # The viewer's stdin is a pipe held open until the end: an EOF there would
    # reach the program as a typed Ctrl-D (script(1) forwards it).
    my ($vin_r, $vin_w);
    if ($attach) {
        pipe($vin_r, $vin_w) or die "pipe: $!";
        $att = fork // die;
        if (!$att) { close $vin_w; open STDIN, "<&", $vin_r; open STDOUT, ">/dev/null"; open STDERR, ">/dev/null";
            my $cmd = join(" ", map { "'$_'" } @viewer);
            exec "/usr/bin/script", "-q", "/dev/null", "/bin/sh", "-c", "stty cols 200 rows 50; exec $cmd" }
        sleep 2;
    }
    my $t = time; $go->(); $done->(); $dt = time - $t;
    my $fp = footprint($kind);
    my $alive = $att ? (kill(0, $att) ? 1 : 0) : 0;
    if ($att) { kill "TERM", $att; waitpid $att, 0; close $vin_w }
    emit({ test => "tput", kind => $kind, attach => $attach ? \1 : \0, viewer_alive => $alive ? \1 : \0,
           bytes => $size + 0, seconds => sprintf("%.3f", $dt) + 0, mb_per_s => sprintf("%.1f", $size / $dt / 1e6) + 0,
           server_rss_kb_after => $fp->{server_rss_kb}, server_cpu_s => $fp->{server_cpu_s} });
}

sub rtt {
    my ($kind, $n) = @_; my $label = "rt" . int(rand(1e6)); my ($send, $read);
    if ($kind eq "mux2") {
        my $id = must($MUX2, "new", "--size", "80x24", "--", "/bin/cat"); chomp $id;
        $send = sub { must($MUX2, "write", $id, "$_[0]\n") };
        $read = sub { (run_cmd($MUX2, "screen", $id))[1] };
    } elsif ($kind eq "rex") {
        must($REX, "--autostart=false", "new", $label, "--shell=none", "--", "/bin/cat");
        $send = sub { must($REX, "--autostart=false", "send", "-s", $label, "$_[0]\n") };
        $read = sub { (run_cmd($REX, "--autostart=false", "capture", "-s", $label))[1] };
    } else {
        my $term = $J->decode(must($CMUX, "--session", "bench", "--json", "workspace", "create", "--name", $label,
                                   "--", "/bin/cat"))->{value}{terminal_id};
        $send = sub { must($CMUX, "--session", "bench", "terminal", $term, "write", "--text", "$_[0]\n") };
        $read = sub { (run_cmd($CMUX, "--session", "bench", "terminal", $term, "screen", "read"))[1] };
    }
    my (@rd, @rt);
    for my $i (1 .. $n) {
        my $m = sprintf("M%05dX", $i);
        my $t = time; $read->(); push @rd, time - $t;
        $t = time; $send->($m); 1 until index($read->(), $m) >= 0; push @rt, time - $t;
    }
    emit({ test => "rtt", kind => $kind, n => $n + 0, read_ms_p50 => pct(\@rd, .5), read_ms_p95 => pct(\@rd, .95),
           send_to_visible_ms_p50 => pct(\@rt, .5), send_to_visible_ms_p95 => pct(\@rt, .95) });
}

my ($cmd, $kind, $arg) = @ARGV;
my %flag = map { $_ => 1 } @ARGV;
if ($cmd eq "scale") { scale($kind, $arg, $flag{"--shell"}) }
elsif ($cmd eq "tput") { tput($kind, $arg, $flag{"--attach"}) }
elsif ($cmd eq "rtt") { rtt($kind, $arg) }
else { die "unknown command $cmd\n" }
