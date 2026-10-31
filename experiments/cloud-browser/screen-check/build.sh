cd /work/cmux-screen
export DEBIAN_FRONTEND=noninteractive
if ! command -v clang++-21 >/dev/null; then
  apt-get update -qq >/dev/null; apt-get install -y -qq lsb-release wget software-properties-common gnupg >/dev/null 2>&1
  curl -sSfL https://apt.llvm.org/llvm.sh -o /tmp/llvm.sh && bash /tmp/llvm.sh 21 >/tmp/llvm.log 2>&1 || tail -5 /tmp/llvm.log
  apt-get install -y -qq libc++-21-dev libc++abi-21-dev >/dev/null 2>&1
fi
clang++-21 --version | head -1
export CC=clang-21 CXX=clang++-21 GOTOOLCHAIN=auto
export RUSTFLAGS="$(for l in $(pkg-config --libs gio-2.0 gobject-2.0 glib-2.0 x11 xext xfixes xdamage xrandr xcomposite xtst gbm libdrm); do printf -- "-C link-arg=%s " "$l"; done)"; echo "RUSTFLAGS=$RUSTFLAGS"
time cargo build --release -p cmux-screen-host > /tmp/build.log 2>&1; echo build-exit $?
grep -E "undefined symbol|^error" /tmp/build.log | sort | uniq -c | head -20
ls -l target/release/cmux-screen-host
