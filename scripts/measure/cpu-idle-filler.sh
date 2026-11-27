#!/bin/bash
# RFD 0182 B2: CPU share of a `CPUWeight=idle` (cgroup cpu.idle) scope against a
# `CPUWeight=100` scope, 2 busy loops each pinned to CPUs 0-1, under the user manager.
# Prints both scopes' usage over a 10 s window and the filler's share (expect ~0%).
# Linux with systemd 252+ and a user manager. Run: cmux-ci run --class exclusive
# --measurement --label measure --script scripts/measure/cpu-idle-filler.sh --ref SHA
set -u
D=${1:-20}
busy='for i in 1 2; do taskset -c 0,1 timeout '"$D"' sh -c "while :; do :; done" & done; wait'
systemd-run --user --quiet --scope --unit=b2idle-task-$$ -p CPUWeight=100 bash -c "$busy" &
A=$!
systemd-run --user --quiet --scope --unit=b2idle-fill-$$ -p CPUWeight=idle bash -c "$busy" &
B=$!
sleep 2
cg() { systemctl --user show -p ControlGroup --value "$1.scope"; }
ta=$(cg b2idle-task-$$); tb=$(cg b2idle-fill-$$)
echo "filler cpu.idle=$(cat /sys/fs/cgroup$tb/cpu.idle) weight=$(cat /sys/fs/cgroup$tb/cpu.weight); task weight=$(cat /sys/fs/cgroup$ta/cpu.weight)"
u() { awk '/^usage_usec/{print $2}' /sys/fs/cgroup$1/cpu.stat; }
a0=$(u $ta); b0=$(u $tb); sleep 10; a1=$(u $ta); b1=$(u $tb)
da=$((a1-a0)); db=$((b1-b0))
echo "task ${da}us filler ${db}us filler share $(awk -v a=$da -v b=$db 'BEGIN{printf "%.2f%%", 100*b/(a+b)}')"
wait $A $B
