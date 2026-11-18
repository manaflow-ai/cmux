#!/usr/bin/env bash
# Isolation test for one macOS user per GUI job (cmuxterm-hq docs/research/gui-ci-partitioning/user-per-job.md).
#
# Leo, 2026-11-17: "we shouldn't necessarily limit things we should have better user partitioning of stuff".
#
# N jobs (n=4 by default, at most 8) run at once on one Mac, each as its own pool account (cmuxci-gui-01..N, made by
# cmuxterm-hq build-fleet/mini-ops/gui-user-pool.sh, which also lets the build user run commands as them with
# `sudo -n -u`). One headless iOS simulator in a device set of its own runs alongside. Each job:
#   - writes a defaults key and a keychain item holding its own random token, from its shell and from its app;
#   - starts a one-window app (window filled with its own colour) in the console session;
#   - gets k+1 presses through the console's CuaDriver (AX, by element), all jobs at once;
#   - has its own window captured by CuaDriver (ScreenCaptureKit window capture); the windows overlap on purpose;
#   - writes and reads a named pasteboard of its own; no job touches the general pasteboard.
# It passes when no job sees another job's defaults, keychain items, clicks or pixels; the general pasteboard's
# change count does not move while no job holds console input; the console user's own defaults and keychain hold no
# job token; and the simulator booted and answered while the jobs ran, in a device set the default set does not list.
#
# A GUI step in the build user's console session, alone on the host:
#   cmux-ci run --class exclusive --label measure --label gui-session-v1 --target-worker WORKER \
#     --script scripts/measure/gui-user-isolation.sh --ref SHA --artifact artifacts/gui-user-isolation.tgz \
#     [--arg=n=4] [--arg=sim=1] --timeout 1800
# Output: ISO {json} lines, an ISO-CHECK line per assertion and `ISO-VERDICT PASS|FAIL`. Exit 0 pass, 1 fail, 4 when
# it could not run (no pool, no CuaDriver, no console session).
set -o pipefail
n=4 sim=1
for arg in "$@"; do
  [[ "$arg" == *$'\n'* ]] && continue
  case "$arg" in
    n=*) n="${arg#n=}" ;;
    sim=*) sim="${arg#sim=}" ;;
    *) echo "gui-user-isolation.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$n" =~ ^[1-8]$ && "$sim" =~ ^[01]$ ]] || { echo "gui-user-isolation.sh: n= is 1..8, sim= 0|1" >&2; exit 2; }

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
out="$root/artifacts/gui-user-isolation"
rm -rf "$out" "$root/artifacts/gui-user-isolation.tgz"
mkdir -p "$out/shots"
chmod 1777 "$out/shots" # the computer-use driver writes the captures here, possibly as another user
work="$(mktemp -d "${TMPDIR:-/tmp}/gup-iso.XXXXXX")"
chmod 711 "$work"
mkdir -p "$work/status"; chmod 1777 "$work/status"
CUA=/Applications/CuaDriver.app/Contents/MacOS/cua-driver
PREFIX=cmuxci-gui-
SVC=dev.cmux.gupiso
say() { printf 'ISO %s\n' "$1" | tee -a "$out/iso.jsonl" >/dev/null; printf 'ISO %s\n' "$1"; }
fails=0 checks=0
check() {  # check NAME OK DETAIL
  checks=$(( checks + 1 ))
  if [[ "$2" == 1 ]]; then echo "ISO-CHECK PASS $1: $3"; else echo "ISO-CHECK FAIL $1: $3"; fails=$(( fails + 1 )); fi
  echo "$1 $2 $3" >>"$out/checks.txt"
}
pids=() sim_udid="" sim_set=""
finish() {
  local j
  for (( j = 0; j < ${#pids[@]}; j++ )); do
    [[ -n "${pids[$j]}" ]] && sudo -n -u "${users[$j]}" /bin/kill "${pids[$j]}" 2>/dev/null
  done
  for u in "${users[@]}"; do
    sudo -n -H -u "$u" /usr/bin/security delete-generic-password -s "$SVC" >/dev/null 2>&1
    sudo -n -H -u "$u" /usr/bin/defaults delete "$SVC" >/dev/null 2>&1
  done
  if [[ -n "$sim_udid" ]]; then
    xcrun simctl --set "$sim_set" shutdown "$sim_udid" >/dev/null 2>&1
    xcrun simctl --set "$sim_set" delete "$sim_udid" >/dev/null 2>&1
  fi
  rm -rf "$work"
  tar -czf "$root/artifacts/gui-user-isolation.tgz" -C "$root/artifacts" gui-user-isolation 2>/dev/null
}
trap finish EXIT
blocked() { echo "ISO-VERDICT BLOCKED: $1"; exit 4; }

# ------------------------------------------------------------------ preconditions
[[ "$(uname)" == Darwin ]] || blocked "not a Mac"
[[ -x "$CUA" ]] || blocked "no CuaDriver.app"
perms=$("$CUA" permissions status 2>&1)
grep -q "Accessibility:.*granted" <<<"$perms" && grep -q "Screen Recording:.*granted" <<<"$perms" ||
  blocked "CuaDriver lacks its grants here: $(tr '\n' ' ' <<<"$perms")"
users=()
for (( k = 1; k <= n; k++ )); do
  u=$(printf '%s%02d' "$PREFIX" "$k")
  id "$u" >/dev/null 2>&1 || blocked "pool account $u does not exist (run cmuxterm-hq build-fleet/mini-ops/gui-user-pool.sh through fleet-sudo)"
  sudo -n -H -u "$u" /usr/bin/true 2>/dev/null || blocked "the build user may not run as $u (no sudoers rule from gui-user-pool.sh)"
  users+=("$u")
done
say "{\"stage\":\"host\",\"host\":\"$(hostname -s)\",\"os\":\"$(sw_vers -productVersion)\",\"chip\":\"$(sysctl -n machdep.cpu.brand_string)\",\"mem_gib\":$(( $(sysctl -n hw.memsize) >> 30 )),\"me\":\"$(id -un)\",\"n\":$n,\"sim\":$sim,\"worker_lease\":\"${CMUX_CI_GUI_USER:-}\"}"

# ------------------------------------------------------------------ helper app
APP="$work/Iso.app"
mkdir -p "$APP/Contents/MacOS"
cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.cmux.gupiso</string>
<key>CFBundleName</key><string>Iso</string>
<key>CFBundleExecutable</key><string>iso</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
cat >"$work/iso.m" <<'OBJC'
// iso: the isolation test's helper.
//   iso app K N TOKEN STATUS X Y   one window filled with palette colour K, button "iso-press"; writes STATUS (JSON)
//                                   at launch and on each press: its defaults, keychain and named pasteboard reads,
//                                   and whether it can read the other pool accounts' preference files
//   iso colors PNG N               pixels of PNG nearest each of the N palette colours (within a distance), JSON
//   iso pbcount                    the general pasteboard's change count
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <ImageIO/ImageIO.h>

static const int PAL[8][3] = {{230, 25, 75}, {60, 180, 75}, {0, 130, 200}, {245, 130, 48},
                              {145, 30, 180}, {70, 240, 240}, {240, 50, 230}, {128, 128, 0}};
static NSString *json(id o) {
  if (![NSJSONSerialization isValidJSONObject:o]) return @"{\"json\":\"invalid\"}";
  NSData *d = [NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingSortedKeys error:nil];
  return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}

@interface Iso : NSObject <NSApplicationDelegate>
@property(strong) NSWindow *window;
@property int k, n;
@property(strong) NSString *token, *status;
@property NSPoint origin;
@property long clicks;
@property(strong) NSMutableDictionary *facts;
@end

@implementation Iso
- (void)write {
  self.facts[@"clicks"] = @(self.clicks);
  NSString *tmp = [self.status stringByAppendingString:@".tmp"];
  [json(self.facts) writeToFile:tmp atomically:NO encoding:NSUTF8StringEncoding error:nil];
  rename(tmp.fileSystemRepresentation, self.status.fileSystemRepresentation);
}
- (NSArray *)keychainTokens {
  NSDictionary *q = @{(id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"dev.cmux.gupiso",
                      (id)kSecMatchLimit : (id)kSecMatchLimitAll, (id)kSecReturnData : @YES};
  CFTypeRef r = NULL;
  OSStatus s = SecItemCopyMatching((__bridge CFDictionaryRef)q, &r);
  NSMutableArray *out = [NSMutableArray array];
  if (s == errSecSuccess && r) {
    NSArray *items = CFGetTypeID(r) == CFArrayGetTypeID() ? (__bridge NSArray *)r : @[ (__bridge id)r ];
    for (NSData *d in items) [out addObject:[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"?"];
  }
  if (r) CFRelease(r);
  return out;
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
  NSMutableDictionary *f = [NSMutableDictionary dictionary];
  self.facts = f;
  f[@"k"] = @(self.k); f[@"pid"] = @(getpid()); f[@"uid"] = @(getuid()); f[@"user"] = NSUserName() ?: @"";
  CGFloat h = NSScreen.screens.count ? NSScreen.screens[0].frame.size.height : 1080;
  NSRect r = NSMakeRect(self.origin.x, h - self.origin.y - 300, 460, 300);
  self.window = [[NSWindow alloc] initWithContentRect:r styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  self.window.releasedWhenClosed = NO;
  self.window.title = [NSString stringWithFormat:@"iso %d: 0", self.k];
  NSView *v = self.window.contentView;
  v.wantsLayer = YES;
  const int *c = PAL[self.k % 8];
  v.layer.backgroundColor = [NSColor colorWithSRGBRed:c[0] / 255.0 green:c[1] / 255.0 blue:c[2] / 255.0 alpha:1].CGColor;
  NSButton *b = [NSButton buttonWithTitle:@"iso-press" target:self action:@selector(press:)];
  b.frame = NSMakeRect(20, 20, 120, 32);
  b.accessibilityIdentifier = @"iso-press";
  [v addSubview:b];
  [self.window orderFront:nil];
  f[@"wid"] = @(self.window.windowNumber);
  // defaults: this account's own domain
  [NSUserDefaults.standardUserDefaults setObject:self.token forKey:@"appToken"];
  CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
  f[@"defaults_app"] = [NSUserDefaults.standardUserDefaults stringForKey:@"appToken"] ?: @"";
  f[@"defaults_shell"] = [NSUserDefaults.standardUserDefaults stringForKey:@"shellToken"] ?: @"";
  // other pool accounts' preference files: readable?
  NSMutableArray *peek = [NSMutableArray array];
  for (int j = 1; j <= self.n; j++) {
    if (j == self.k + 1) continue;
    NSString *p = [NSString stringWithFormat:@"/Users/cmuxci-gui-%02d/Library/Preferences/dev.cmux.gupiso.plist", j];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    if (d) [peek addObject:@{@"path" : p, @"keys" : d.allKeys}];
  }
  f[@"others_defaults_read"] = peek;
  // keychain: add our item, then list every item of the service we can see
  NSDictionary *add = @{(id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"dev.cmux.gupiso",
                        (id)kSecAttrAccount : @"app", (id)kSecValueData : [self.token dataUsingEncoding:NSUTF8StringEncoding]};
  SecItemDelete((__bridge CFDictionaryRef)@{(id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"dev.cmux.gupiso", (id)kSecAttrAccount : @"app"});
  f[@"keychain_add"] = @(SecItemAdd((__bridge CFDictionaryRef)add, NULL));
  f[@"keychain_seen"] = [self keychainTokens];
  // a named pasteboard of its own; never the general one
  NSPasteboard *pb = [NSPasteboard pasteboardWithName:[NSString stringWithFormat:@"dev.cmux.gupiso.%@", self.token]];
  [pb clearContents];
  [pb setString:self.token forType:NSPasteboardTypeString];
  f[@"named_pb"] = [pb stringForType:NSPasteboardTypeString] ?: @"";
  f[@"general_pb_has_token"] = @([[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] ?: @"" containsString:@"gupiso-"]);
  [self write];
}
- (void)press:(id)sender {
  self.clicks++;
  self.window.title = [NSString stringWithFormat:@"iso %d: %ld", self.k, self.clicks];
  [self write];
}
@end

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc >= 2 && !strcmp(argv[1], "pbcount")) {
      printf("%ld\n", (long)NSPasteboard.generalPasteboard.changeCount);
      return 0;
    }
    if (argc >= 4 && !strcmp(argv[1], "colors")) {
      int n = atoi(argv[3]);
      CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[2])], NULL);
      CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
      if (!img) { printf("{\"ok\":false}\n"); return 0; }
      size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
      uint8_t *px = calloc(w * h, 4);
      CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
      CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
      CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
      long counts[8] = {0}, total = (long)(w * h);
      for (size_t i = 0; i < w * h; i++) {
        int r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2], best = -1, bd = 40 * 40 * 3;
        for (int k = 0; k < n; k++) {
          int d = (r - PAL[k][0]) * (r - PAL[k][0]) + (g - PAL[k][1]) * (g - PAL[k][1]) + (b - PAL[k][2]) * (b - PAL[k][2]);
          if (d < bd) { bd = d; best = k; }
        }
        if (best >= 0) counts[best]++;
      }
      NSMutableArray *frac = [NSMutableArray array];
      for (int k = 0; k < n; k++) [frac addObject:@((double)counts[k] / (double)total)];
      printf("%s\n", json(@{@"ok" : @YES, @"w" : @(w), @"h" : @(h), @"frac" : frac}).UTF8String);
      return 0;
    }
    if (argc >= 8 && !strcmp(argv[1], "app")) {
      [NSApplication sharedApplication];
      [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
      Iso *d = [Iso new];
      d.k = atoi(argv[2]); d.n = atoi(argv[3]); d.token = @(argv[4]); d.status = @(argv[5]);
      d.origin = NSMakePoint(atof(argv[6]), atof(argv[7]));
      NSApp.delegate = d;
      [NSApp run];
      return 0;
    }
    return 2;
  }
}
OBJC
xcrun clang -fobjc-arc -O1 -o "$APP/Contents/MacOS/iso" "$work/iso.m" -framework AppKit -framework Security \
  -framework ImageIO -framework CoreGraphics >"$out/build.log" 2>&1 || blocked "helper did not compile: $(tail -5 "$out/build.log" | tr '\n' ' ')"
codesign -s - -f "$APP" >/dev/null 2>&1
chmod -R a+rX "$APP"
ISO="$APP/Contents/MacOS/iso"
field() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

# ------------------------------------------------------------------ the simulator, alongside
sim_log="$out/sim.txt"
if [[ "$sim" == 1 ]]; then
  sim_set="$work/simset"; mkdir -p "$sim_set"
  (
    t0=$(date +%s)
    read -r rt dt <<<"$(xcrun simctl list -j runtimes devicetypes | python3 -I "$root/scripts/ci/ios_sim_runtime.py" 2>/dev/null)"
    [[ -n "$rt" && -n "$dt" ]] || { echo "sim: no runtime"; exit 1; }
    udid=$(xcrun simctl --set "$sim_set" create gupiso-sim "$dt" "$rt") || { echo "sim: create failed"; exit 1; }
    echo "udid $udid"
    xcrun simctl --set "$sim_set" boot "$udid" || { echo "sim: boot failed"; exit 1; }
    xcrun simctl --set "$sim_set" bootstatus "$udid" -b >/dev/null 2>&1
    echo "booted_s $(( $(date +%s) - t0 ))"
    echo "boot_at $(date +%s)"
    xcrun simctl --set "$sim_set" spawn "$udid" /usr/bin/defaults write dev.cmux.gupiso simToken gupiso-sim
    echo "sim_defaults $(xcrun simctl --set "$sim_set" spawn "$udid" /usr/bin/defaults read dev.cmux.gupiso simToken 2>&1)"
    echo "in_default_set $(xcrun simctl list devices -j | grep -c "$udid")"
    echo "done_at $(date +%s)"
  ) >"$sim_log" 2>&1 &
  sim_pid=$!
  sim_t0=$(date +%s)
fi

# ------------------------------------------------------------------ the jobs
pb_before=$("$ISO" pbcount)
tokens=()
for (( k = 0; k < n; k++ )); do
  u="${users[$k]}"
  tok="gupiso-$k-$(LC_ALL=C tr -dc a-z0-9 </dev/urandom | head -c 12)"
  tokens+=("$tok")
  # the job's shell: a login keychain if it has none, its old items gone, then its defaults and keychain item
  if ! sudo -n -H -u "$u" /usr/bin/security default-keychain 2>/dev/null | grep -q keychain; then
    sudo -n -H -u "$u" /usr/bin/security create-keychain -p "" "/Users/$u/Library/Keychains/login.keychain-db" >/dev/null 2>&1
    sudo -n -H -u "$u" /usr/bin/security default-keychain -s "/Users/$u/Library/Keychains/login.keychain-db" >/dev/null 2>&1
  fi
  sudo -n -H -u "$u" /usr/bin/security unlock-keychain -p "" "/Users/$u/Library/Keychains/login.keychain-db" >/dev/null 2>&1
  while sudo -n -H -u "$u" /usr/bin/security delete-generic-password -s "$SVC" >/dev/null 2>&1; do :; done
  sudo -n -H -u "$u" /usr/bin/defaults delete "$SVC" >/dev/null 2>&1
  sudo -n -H -u "$u" /usr/bin/defaults write "$SVC" shellToken "$tok"
  sudo -n -H -u "$u" /usr/bin/security add-generic-password -s "$SVC" -a shell -w "$tok" >/dev/null 2>&1
done
t_start=$(date +%s)
for (( k = 0; k < n; k++ )); do
  # overlapping windows, 70 points apart: a display crop would show the neighbours, a window capture must not
  sudo -n -H -u "${users[$k]}" "$ISO" app "$k" "$n" "${tokens[$k]}" "$work/status/job$k.json" $(( 60 + k * 70 )) $(( 80 + k * 50 )) \
    >"$out/app$k.log" 2>&1 &
done
for (( k = 0; k < n; k++ )); do
  end=$(( $(date +%s) + 60 ))
  while [[ ! -s "$work/status/job$k.json" && $(date +%s) -lt $end ]]; do sleep 0.2; done
  pids[$k]=$(field "$work/status/job$k.json" pid)
done
say "{\"stage\":\"up\",\"jobs\":$n,\"up_s\":$(( $(date +%s) - t_start )),\"pids\":\"${pids[*]}\"}"

# press_job K TIMES: CuaDriver reads job K's window, finds its button, presses it TIMES times (AX), and captures it
press_job() {
  local k="$1" times="$2" pid wid raw tok i shot="$out/shots/job$1.png"
  pid=$(field "$work/status/job$k.json" pid); wid=$(field "$work/status/job$k.json" wid)
  raw=$("$CUA" call get_window_state "{\"pid\":$pid,\"window_id\":$wid,\"include_accessibility_tree\":true,\"screenshot_out_file\":\"$shot\"}" 2>&1)
  tok=$(printf '%s' "$raw" | python3 -I -c '
import json, sys
try:
    a = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
s = a.get("structuredContent") if isinstance(a.get("structuredContent"), dict) else a
for e in s.get("elements") or []:
    if e.get("role") == "AXButton" and "iso-press" in (str(e.get("label")) + str(e.get("title")) + str(e.get("identifier"))) and e.get("element_token"):
        print(e["element_token"]); break
' 2>/dev/null)
  [[ -n "$tok" ]] || { echo "job $k: no button in the AX tree: ${raw:0:300}" >"$out/press$k.txt"; return; }
  for (( i = 0; i < times; i++ )); do
    "$CUA" call click "{\"pid\":$pid,\"window_id\":$wid,\"element_token\":\"$tok\",\"action\":\"press\"}" >>"$out/press$k.txt" 2>&1
  done
}
# The presses and captures run only once the simulator is booted, so it is up beside every job while they run
# (bounded: a simulator that never boots fails sim-alongside-jobs instead of holding the test).
if [[ -n "${sim_pid:-}" ]]; then
  end=$(( $(date +%s) + 300 ))
  while ! grep -q "^boot_at " "$sim_log" 2>/dev/null && kill -0 "$sim_pid" 2>/dev/null && (( $(date +%s) < end )); do sleep 0.5; done
fi
t_press=$(date +%s)
press_pids=()
for (( k = 0; k < n; k++ )); do press_job "$k" $(( k + 1 )) & press_pids+=($!); done
wait "${press_pids[@]}"
# the presses are counted by the apps; give the last ones a moment to land
end=$(( $(date +%s) + 10 ))
while (( $(date +%s) < end )); do
  done_all=1
  for (( k = 0; k < n; k++ )); do c=$(field "$work/status/job$k.json" clicks); (( ${c:-0} >= k + 1 )) || done_all=0; done
  (( done_all )) && break
  sleep 0.2
done
t_end=$(date +%s)
say "{\"stage\":\"pressed\",\"s\":$(( t_end - t_press ))}"
[[ -n "${sim_pid:-}" ]] && wait "$sim_pid"
t_sim_waited=$(date +%s)
# every job's app is still up here (they are stopped at the end), so the simulator ran beside all of them
alive=0; for p in "${pids[@]}"; do [[ -n "$p" ]] && ps -p "$p" >/dev/null 2>&1 && alive=$(( alive + 1 )); done
pb_after=$("$ISO" pbcount)

# ------------------------------------------------------------------ assertions
for (( k = 0; k < n; k++ )); do
  st="$work/status/job$k.json"; cp "$st" "$out/job$k.json" 2>/dev/null
  u="${users[$k]}"; tok="${tokens[$k]}"
  check "job$k-runs-as-own-user" "$([[ "$(field "$st" user)" == "$u" ]] && echo 1 || echo 0)" "user=$(field "$st" user) uid=$(field "$st" uid)"
  check "job$k-clicks" "$([[ "$(field "$st" clicks)" == $(( k + 1 )) ]] && echo 1 || echo 0)" "got $(field "$st" clicks), sent $(( k + 1 ))"
  check "job$k-defaults-app" "$([[ "$(field "$st" defaults_app)" == "$tok" ]] && echo 1 || echo 0)" "$(field "$st" defaults_app)"
  check "job$k-defaults-shell" "$([[ "$(field "$st" defaults_shell)" == "$tok" ]] && echo 1 || echo 0)" "the app read its shell's value: $(field "$st" defaults_shell)"
  peer=$(plutil -extract others_defaults_read json -o - "$st" 2>/dev/null)
  check "job$k-no-peer-defaults" "$([[ "$peer" == "[]" ]] && echo 1 || echo 0)" "readable peer preference files: ${peer:-unread}"
  seen=$(plutil -extract keychain_seen json -o - "$st" 2>/dev/null)
  own_only=1
  for (( j = 0; j < n; j++ )); do (( j == k )) && continue; grep -q "${tokens[$j]}" <<<"$seen" && own_only=0; done
  grep -q "$tok" <<<"$seen" || own_only=0
  check "job$k-keychain-own-only" "$own_only" "items seen: $seen"
  check "job$k-named-pasteboard" "$([[ "$(field "$st" named_pb)" == "$tok" ]] && echo 1 || echo 0)" "$(field "$st" named_pb)"
  check "job$k-general-pasteboard-clean" "$([[ "$(field "$st" general_pb_has_token)" == false ]] && echo 1 || echo 0)" "no job token on the general pasteboard"
  shot="$out/shots/job$k.png"
  if [[ -s "$shot" ]]; then
    cols=$("$ISO" colors "$shot" "$n")
    echo "$cols" >"$out/shots/job$k.colors.json"
    verdict=$(python3 -I -c '
import json, sys
k, c = int(sys.argv[1]), json.loads(sys.argv[2])
f = c.get("frac") or []
own = f[k] if k < len(f) else 0
other = max([x for j, x in enumerate(f) if j != k] or [0])
print("1" if own >= 0.3 and other <= 0.005 else "0", "own %.3f, largest other %.4f" % (own, other))' "$k" "$cols")
    check "job$k-capture-own-pixels" "${verdict%% *}" "${verdict#* }"
  else
    check "job$k-capture-own-pixels" 0 "no capture: $(head -c 300 "$out/press$k.txt" 2>/dev/null)"
  fi
done
check "general-pasteboard-untouched" "$([[ "$pb_before" == "$pb_after" ]] && echo 1 || echo 0)" "change count $pb_before -> $pb_after"
console_defaults=$(/usr/bin/defaults read "$SVC" 2>/dev/null)
console_kc=$(/usr/bin/security find-generic-password -s "$SVC" 2>&1 | head -1)
leak=0; for t in "${tokens[@]}"; do grep -q "$t" <<<"$console_defaults$console_kc" && leak=1; done
check "console-user-untouched" "$(( 1 - leak ))" "console defaults: ${console_defaults:-none}; keychain: $console_kc"
if [[ "$sim" == 1 ]]; then
  cat "$sim_log" | sed 's/^/ISO-SIM /'
  sim_udid=$(awk '/^udid /{print $2}' "$sim_log")
  boot_at=$(awk '/^boot_at /{print $2}' "$sim_log"); done_at=$(awk '/^done_at /{print $2}' "$sim_log")
  check "sim-answered" "$(grep -q 'sim_defaults gupiso-sim' "$sim_log" && echo 1 || echo 0)" "$(grep sim_defaults "$sim_log")"
  check "sim-own-device-set" "$(grep -q '^in_default_set 0' "$sim_log" && echo 1 || echo 0)" "$(grep in_default_set "$sim_log")"
  check "sim-alongside-jobs" "$([[ -n "$boot_at" && "$boot_at" -le "$t_press" && "$alive" == "$n" ]] && echo 1 || echo 0)" "sim started $sim_t0 (presses $t_press..$t_end), booted ${boot_at:-never}, answered ${done_at:-never}; $alive of $n job apps still up at $t_sim_waited"
fi
say "{\"stage\":\"verdict\",\"checks\":$checks,\"failed\":$fails}"
if (( fails == 0 )); then echo "ISO-VERDICT PASS ($checks checks, $n jobs$([[ "$sim" == 1 ]] && echo ', 1 simulator'))"; exit 0; fi
echo "ISO-VERDICT FAIL ($fails of $checks checks failed)"; exit 1
