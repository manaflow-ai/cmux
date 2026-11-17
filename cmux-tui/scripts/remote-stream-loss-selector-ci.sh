#!/usr/bin/env bash
# The loss-selector rows through `cmux-ci test --artifact DIR`: builds
# remote_stream_bench, then runs each lossy row of the connectivity map in its
# own network namespace inside an ephemeral Linux guest that has netem (the
# guest recipe of remote-stream-netem-ci.sh; the CI host kernel may lack it).
set -euo pipefail
FAST_CHECKS_OUT=${FAST_CHECKS_OUT:-$(mktemp -d)}
runs=${RUNS:-3} secs=${SECS:-8}
sudo -n apt-get update -qq
sudo -n apt-get install -y -qq --no-install-recommends qemu-system-x86 busybox-static cpio kmod iproute2 ethtool zstd
scratch=$(mktemp -d)
root=$scratch/root
mkdir -p "$root" "$scratch/packages"
image_pkg=$(apt-cache depends linux-image-virtual | awk '/Depends: linux-image-[0-9]/{print $2;exit}')
test -n "$image_pkg"
modules_pkg=${image_pkg/linux-image-/linux-modules-}
(cd "$scratch/packages" && apt-get download "$image_pkg" "$modules_pkg")
for deb in "$scratch"/packages/*.deb; do dpkg-deb -x "$deb" "$root"; done
kernel=$(basename "$(echo "$root"/boot/vmlinuz-*)" | sed 's/vmlinuz-//')
(cd cmux-tui && cargo build --release --locked -p cmux-wg --example remote_stream_bench)
bin="${CARGO_TARGET_DIR:-$PWD/cmux-tui/target}/release/examples/remote_stream_bench"
mkdir -p "$root/bin" "$root/dev" "$root/proc" "$root/sys" "$root/tmp" "$root/run"
cp /bin/busybox "$root/bin/busybox"
copy_binary() {
  local source=$1 destination=$2
  mkdir -p "$root$(dirname "$destination")"
  cp -L "$source" "$root$destination"
  while read -r lib; do
    mkdir -p "$root$(dirname "$lib")"
    cp -L "$lib" "$root$lib"
  done < <(ldd "$source" | awk '/=> \// {print $3} /^\s*\// {print $1}' | sort -u)
}
for cmd in bash ip tc ethtool timeout python3; do copy_binary "$(command -v "$cmd")" "/bin/$cmd"; done
copy_binary "$bin" /bench-bin
python_lib=$(python3 -c 'import sysconfig;print(sysconfig.get_path("stdlib"))')
mkdir -p "$root$python_lib"
cp -r "$python_lib/encodings" "$root$python_lib/encodings"
loader=$(ldd "$bin" | awk '/ld-linux/{print $1}')
mkdir -p "$root$(dirname "$loader")"
cp -L "$loader" "$root$loader"
if test -d /usr/lib/x86_64-linux-gnu/tc; then
  mkdir -p "$root/usr/lib/x86_64-linux-gnu"
  cp -r /usr/lib/x86_64-linux-gnu/tc "$root/usr/lib/x86_64-linux-gnu/"
fi
while IFS= read -r -d '' module; do zstd -dq --rm "$module"; done < <(find "$root/lib/modules" "$root/usr/lib/modules" -name '*.ko.zst' -print0 2>/dev/null || true)
depmod -b "$root" "$kernel"
cp cmux-tui/scripts/remote-stream-loss-selector-bench.sh "$root/bench.sh"
cat > "$root/init" <<INIT
#!/bin/busybox sh
/bin/busybox --install -s /bin
export PATH=/bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
modprobe sch_netem || { echo NETEM_GUEST_MODULE_FAILED; poweroff -f; }
for row in "50 0" "50 2" "150 1" "100 3"; do
  set -- \$row
  echo "NETEM_BEGIN rtt=\$1 loss=\$2"
  unshare -n bash /bench.sh /bench-bin \$1 \$2 $runs $secs || { echo NETEM_GUEST_BENCH_FAILED; poweroff -f; }
  echo "NETEM_END rtt=\$1 loss=\$2"
done
echo NETEM_GUEST_SUCCESS
poweroff -f
INIT
chmod +x "$root/init"
(cd "$root" && find . -print0 | cpio --null -o --format=newc --quiet | gzip -1 > "$scratch/initrd.gz")
printf 'NETEM_GUEST_ACCEL='; if test -r /dev/kvm && test -w /dev/kvm; then echo kvm; else echo tcg; fi
timeout 5000 qemu-system-x86_64 -machine accel=kvm:tcg -cpu max -m 4096 -smp 4 -nographic -no-reboot -kernel "$root/boot/vmlinuz-$kernel" -initrd "$scratch/initrd.gz" -append 'console=ttyS0 rdinit=/init panic=-1' | tee "$FAST_CHECKS_OUT/netem-guest.log"
grep -q '^NETEM_GUEST_SUCCESS' "$FAST_CHECKS_OUT/netem-guest.log"
grep '^{"rtt_ms"' "$FAST_CHECKS_OUT/netem-guest.log" | tr -d '\r' > "$FAST_CHECKS_OUT/loss-selector.jsonl"
python3 cmux-tui/scripts/remote-stream-loss-selector-table.py "$FAST_CHECKS_OUT/loss-selector.jsonl" | tee "$FAST_CHECKS_OUT/loss-selector.md"
