#!/usr/bin/env bash
# Reproduce the paired loss measurements through cmux-ci test --artifact DIR.
set -euo pipefail
: "${FAST_CHECKS_OUT:?Run through cmux-ci test --artifact DIR}"
# An ephemeral Linux guest supplies netem when the CI host kernel omits it.
# Both revisions and all control transports run in this same guest.
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
printf 'NETEM_GUEST_KERNEL=%s\n' "$kernel"
# Build the two revisions without changing the branch: only restore the old
# congestion-controller source for the baseline build, then put HEAD back.
source=cmux-tui/vendor/smoltcp/src/socket/tcp/congestion/cubic.rs
printf '%s  %s\n' '76e8acdd36279e7072b5b7200920ed9f2a3e18da342d42865db66bcdfbaecc05' "$source" | sha256sum -c -
cp "$source" "$scratch/cubic-after.rs"
trap 'cp "$scratch/cubic-after.rs" "$source"' EXIT
patch -p1 <<'BASELINE_PATCH'
diff --git a/cmux-tui/vendor/smoltcp/src/socket/tcp/congestion/cubic.rs b/cmux-tui/vendor/smoltcp/src/socket/tcp/congestion/cubic.rs
index 6c2cc470a57..ef614fa3cd3 100644
--- a/cmux-tui/vendor/smoltcp/src/socket/tcp/congestion/cubic.rs
+++ b/cmux-tui/vendor/smoltcp/src/socket/tcp/congestion/cubic.rs
@@ -150,11 +150,7 @@ impl Controller for Cubic {
         let w_est = {
             let alpha = if self.w_est >= self.cwnd_prior as f64 { 1.0 } else { ALPHA_CUBIC };
 
-            // cmux patch: RFC 9438 counts all newly acknowledged bytes in
-            // congestion avoidance. The one-MSS cap belongs to slow start;
-            // using it here penalizes delayed ACKs and cumulative ACKs after
-            // a repaired hole, starving a busy stream of window growth.
-            self.w_est += alpha * self.mss as f64 * len as f64 / self.cwnd as f64;
+            self.w_est += alpha * self.mss as f64 * segment as f64 / self.cwnd as f64;
             self.w_est
         };
 
@@ -176,7 +172,7 @@ impl Controller for Cubic {
 
         // TODO: clamps to 0 on small w_cubic_target (i.e. close to plateau)
         // add additional counter (linux `cwnd_cnt`?) to track "lost" bytes
-        let increment = (w_cubic_target as usize).saturating_sub(self.cwnd) * len / self.cwnd;
+        let increment = (w_cubic_target as usize).saturating_sub(self.cwnd) * segment / self.cwnd;
         self.cwnd = (self.cwnd + increment).min(self.rwnd).max(self.mss);
     }
 
BASELINE_PATCH
printf '%s  %s\n' 'bc3eacf894d32871c5be1ff093e3c79538a4d613a401503ffe83af23390eb99a' "$source" | sha256sum -c -
(cd cmux-tui && cargo build --release --locked -p cmux-wg --example remote_stream_bench)
cp "${CARGO_TARGET_DIR:-$PWD/cmux-tui/target}/release/examples/remote_stream_bench" "$scratch/before"
cp "$scratch/cubic-after.rs" "$source"
(cd cmux-tui && cargo build --release --locked -p cmux-wg --example remote_stream_bench)
cp "${CARGO_TARGET_DIR:-$PWD/cmux-tui/target}/release/examples/remote_stream_bench" "$scratch/after"
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
copy_binary "$scratch/before" /before
copy_binary "$scratch/after" /after
python_lib=$(python3 -c 'import sysconfig;print(sysconfig.get_path("stdlib"))')
mkdir -p "$root$python_lib"
cp -r "$python_lib/encodings" "$root$python_lib/encodings"
# libc's loader line has no =>; include its resolved path explicitly.
loader=$(ldd "$scratch/after" | awk '/ld-linux/{print $1}')
mkdir -p "$root$(dirname "$loader")"
cp -L "$loader" "$root$loader"
if test -d /usr/lib/x86_64-linux-gnu/tc; then
  mkdir -p "$root/usr/lib/x86_64-linux-gnu"
  cp -r /usr/lib/x86_64-linux-gnu/tc "$root/usr/lib/x86_64-linux-gnu/"
fi
# Busybox modprobe understands uncompressed modules.
while IFS= read -r -d '' module; do zstd -dq --rm "$module"; done < <(find "$root/lib/modules" "$root/usr/lib/modules" -name '*.ko.zst' -print0 2>/dev/null || true)
depmod -b "$root" "$kernel"
cp cmux-tui/scripts/remote-stream-netem-bench.sh "$root/bench.sh"
cat > "$root/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox --install -s /bin
export PATH=/bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
modprobe sch_netem || { echo NETEM_GUEST_MODULE_FAILED; poweroff -f; }
uname -a
# No shaping or offload state carries from one revision to the next.
for revision in before after; do
  for loss in 0 2; do
    echo "NETEM_BEGIN revision=$revision loss=$loss"
    unshare -n bash /bench.sh /$revision 50 "$loss" 3 8 || { echo NETEM_GUEST_BENCH_FAILED; poweroff -f; }
    echo "NETEM_END revision=$revision loss=$loss"
  done
done
echo NETEM_GUEST_SUCCESS
poweroff -f
INIT
chmod +x "$root/init"
(cd "$root" && find . -print0 | cpio --null -o --format=newc --quiet | gzip -1 > "$scratch/initrd.gz")
printf 'NETEM_GUEST_ACCEL='; if test -r /dev/kvm && test -w /dev/kvm; then echo kvm; else echo tcg; fi
timeout 1200 qemu-system-x86_64 -machine accel=kvm:tcg -cpu max -m 2048 -smp 2 -nographic -no-reboot -kernel "$root/boot/vmlinuz-$kernel" -initrd "$scratch/initrd.gz" -append 'console=ttyS0 rdinit=/init panic=-1' | tee "$FAST_CHECKS_OUT/netem-guest.log"
grep -q '^NETEM_GUEST_SUCCESS' "$FAST_CHECKS_OUT/netem-guest.log"
