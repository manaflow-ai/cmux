#!/usr/bin/env bash
# One macOS user per GUI / computer-use CI job (cmuxterm-hq docs/research/gui-ci-partitioning/user-per-job.md).
#
# Leo, 2026-11-17: "we shouldn't necessarily limit things we should have better user partitioning of stuff".
# The idea: a pool of test accounts (cmuxci-gui-01..08), one per GUI job, so jobs never share a home,
# keychain, defaults, TCC rows or DerivedData. This probe answers, on one Mac:
#   (a) can such an account's processes, with no loginwindow login of its own, run WindowServer-backed apps
#       whose windows a computer-use driver can capture (ScreenCaptureKit) and press (AX)? Three routes:
#         own     `launchctl asuser POOL_UID`: the account's own bootstrap, no GUI session;
#         console `launchctl asuser CONSOLE_UID` then setuid to the account: the console session's
#                 WindowServer and bootstrap, the account's uid, home, defaults and keychain;
#         gui     `launchctl print gui/POOL_UID`: a gui domain without a loginwindow login (expected absent);
#       plus what leaks across accounts in the console route (pasteboard, defaults, keychain).
#   (b) how TCC grants reach a pool account: SIP and MDM state, whether root may write the system or a user
#       TCC.db (a no-op BEGIN IMMEDIATE; ROLLBACK), and whether the console's granted CuaDriver captures and
#       presses another uid's window;
#   (c) the cost of each extra account: processes and resident memory per pool uid with 1,2,4,8 accounts'
#       apps up, host CPU and memory, and a full logged-in GUI session's cost (the console user's own
#       processes) for comparison;
#   (d) setup and teardown: sysadminctl -addUser, createhomedir, a login keychain, home size, secure token,
#       a home reset (rm + createhomedir), launchctl bootout, sysadminctl -deleteUser.
#
# Two modes, by who runs it:
#   - as root (the pool stages; creating accounts needs root, which a fleet step does not have):
#       fleet-sudo HOST -f scripts/measure/gui-user-per-job.sh        (on a leased fleet mini; its console
#       user must be logged in). Every account it makes is named cmuxci-gui-NN, full name "cmuxci gui pool
#       probe", UID 5101.., hidden from the login window, and deleted on exit (trap), whatever happened.
#       Arguments cannot pass through fleet-sudo -f, so the defaults below are the run.
#   - as the build user (a controller measurement): only the host, TCC and console-session stages:
#       cmux-ci run --class exclusive --label measure --script scripts/measure/gui-user-per-job.sh --ref SHA
# Output: one `GUP {json}` line per measurement on stdout, a `GUP-SUMMARY` block at the end. Exit 0 when
# every stage ran (a refusal it measured is a result, not a failure), 4 when a stage could not run.
# Not set -u: macOS /bin/bash 3.2, which fleet-sudo may run this with, calls an empty "${arr[@]}" unbound.
set -o pipefail
pool_n=8
ns="1,2,4,8"
for arg in "$@"; do
  case "$arg" in
    n=*) pool_n="${arg#n=}" ;;
    ns=*) ns="${arg#ns=}" ;;
    *) echo "gui-user-per-job.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$pool_n" =~ ^[1-9]$|^1[0-6]$ ]] || { echo "gui-user-per-job.sh: n= is 1..16" >&2; exit 2; }
[[ "$ns" =~ ^[0-9]{1,2}(,[0-9]{1,2})*$ ]] || { echo "gui-user-per-job.sh: ns= is a comma list" >&2; exit 2; }

PREFIX=cmuxci-gui-
MARK="cmuxci gui pool probe"
UID0=5100
WORK="/Users/Shared/gup-probe.$$"
CUA=/Applications/CuaDriver.app/Contents/MacOS/cua-driver
failed=0
created=()

say() { printf 'GUP %s\n' "$1"; }
note() { echo "GUP-NOTE $(date -u +%H:%M:%S) $*" >&2; }
# jstr: a JSON string of $1 (backslash, quote and control characters escaped; cut to 600 characters).
jstr() {
  local s="${1:0:600}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"; s="${s//$'\t'/ }"
  printf '"%s"' "$s"
}
now() { "$WORK/gup" now 2>/dev/null || date +%s; }
ms_since() { "$WORK/gup" since "$1"; }

# remove_account U: its processes (by PID; every process of a pool uid is this probe's), its launchd domains, the
# account and its home. Only ever called for cmuxci-gui-NN accounts whose full name is $MARK.
remove_account() {
  local u="$1" uid pids
  uid=$(dscl . -read "/Users/$u" UniqueID 2>/dev/null | awk '{print $2}')
  [[ -n "$uid" ]] || return 0
  pids=$(ps -axo pid=,uid= | awk -v x="$uid" '$2 == x {print $1}')
  [[ -n "$pids" ]] && kill $pids 2>/dev/null
  launchctl bootout "user/$uid" >/dev/null 2>&1
  launchctl bootout "gui/$uid" >/dev/null 2>&1
  sysadminctl -deleteUser "$u" >/dev/null 2>&1 || dscl . -delete "/Users/$u" >/dev/null 2>&1
  [[ -d "/Users/$u" ]] && rm -rf "/Users/$u"
  if dscl . -read "/Users/$u" >/dev/null 2>&1; then note "cleanup: $u still exists"; else note "cleanup: $u removed"; fi
}
cleanup() {
  local u
  for u in "${created[@]}"; do remove_account "$u"; done
  created=()
  [[ -n "${base_pids:-}" ]] && kill $base_pids 2>/dev/null
  [[ -d "$WORK" ]] && rm -rf "$WORK"
}

# ------------------------------------------------------------------ the helper (AppKit app + driver checks)
mkdir -p "$WORK/status" "$WORK/shots"
chmod 755 "$WORK"; chmod 1777 "$WORK/status" "$WORK/shots"
cat >"$WORK/gup.m" <<'OBJC'
// gup: the pool-account probe's helper. `gup app TAG STATUS X Y` is a one-window AppKit app (button
// "gup-press" counts clicks into the window title); it writes STATUS (JSON) when its window is up and on
// each click: who it runs as, its session, and what its defaults, keychain and pasteboard writes did.
// `gup windows PID`, `gup session`, `gup mem PID`, `gup now`, `gup since T` are driver-side reads.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Security/Security.h>
#import <bsm/audit.h>
#import <libproc.h>
#import <sys/sysctl.h>
#include <pwd.h>

static double now_s(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec + tv.tv_usec / 1e6; }
static NSString *json(id o) {
  if (![NSJSONSerialization isValidJSONObject:o]) return @"{\"json\":\"invalid\"}";
  NSData *d = [NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingSortedKeys error:nil];
  return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}
static double proc_start(pid_t pid) {
  struct kinfo_proc kp; size_t len = sizeof(kp); int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len == 0) return 0;
  return kp.kp_proc.p_starttime.tv_sec + kp.kp_proc.p_starttime.tv_usec / 1e6;
}
static NSDictionary *session(void) {
  NSMutableDictionary *m = [NSMutableDictionary dictionary];
  CFDictionaryRef s = CGSessionCopyCurrentDictionary();
  m[@"cg_session"] = s ? @YES : @NO;
  if (s) {
    NSDictionary *d = (__bridge NSDictionary *)s;
    for (NSString *k in @[ @"kCGSSessionOnConsoleKey", @"kCGSSessionUserIDKey", @"kCGSSessionUserNameKey", @"kCGSessionLoginDoneKey", @"kCGSSessionIDKey" ])
      if (d[k]) m[k] = d[k];
    CFRelease(s);
  }
  auditinfo_addr_t ai; memset(&ai, 0, sizeof(ai));
  if (getaudit_addr(&ai, sizeof(ai)) == 0) { m[@"asid"] = @(ai.ai_asid); m[@"auid"] = @(ai.ai_auid); }
  m[@"uid"] = @(getuid()); m[@"euid"] = @(geteuid());
  m[@"ax_trusted"] = @(AXIsProcessTrusted());
  m[@"sr_preflight"] = @(CGPreflightScreenCaptureAccess());
  return m;
}

@interface GupApp : NSObject <NSApplicationDelegate>
@property(strong) NSWindow *window;
@property(strong) NSButton *button;
@property(strong) NSString *tag, *status;
@property NSPoint origin;
@property long clicks;
@property(strong) NSMutableDictionary *facts;
@end

@implementation GupApp
- (void)write {
  self.facts[@"clicks"] = @(self.clicks);
  self.facts[@"t_write"] = @(now_s());
  NSString *tmp = [self.status stringByAppendingString:@".tmp"];
  [json(self.facts) writeToFile:tmp atomically:NO encoding:NSUTF8StringEncoding error:nil];
  rename(tmp.fileSystemRepresentation, self.status.fileSystemRepresentation);
}
- (void)applicationDidFinishLaunching:(NSNotification *)n {
  NSMutableDictionary *f = [NSMutableDictionary dictionary];
  self.facts = f;
  f[@"tag"] = self.tag;
  f[@"pid"] = @(getpid());
  f[@"user"] = NSUserName() ?: @"";
  f[@"home"] = NSHomeDirectory() ?: @"";
  f[@"env_home"] = @(getenv("HOME") ?: "");
  [f addEntriesFromDictionary:session()];
  CGFloat h = NSScreen.screens.count ? NSScreen.screens[0].frame.size.height : 1080;
  NSRect r = NSMakeRect(self.origin.x, h - self.origin.y - 160, 420, 160);
  self.window = [[NSWindow alloc] initWithContentRect:r styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                              backing:NSBackingStoreBuffered defer:NO];
  self.window.releasedWhenClosed = NO;
  self.window.title = [NSString stringWithFormat:@"gup %@: 0", self.tag];
  self.button = [NSButton buttonWithTitle:@"gup-press" target:self action:@selector(press:)];
  self.button.frame = NSMakeRect(20, 20, 200, 48);
  self.button.accessibilityIdentifier = @"gup-press";
  [self.window.contentView addSubview:self.button];
  [self.window orderFront:nil];
  f[@"wid"] = @(self.window.windowNumber);
  f[@"screens"] = @(NSScreen.screens.count);
  double t0 = proc_start(getpid());
  f[@"ready_ms"] = @(t0 > 0 ? (now_s() - t0) * 1000 : -1);
  // defaults: this account's own preferences domain
  NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
  [ud setObject:self.tag forKey:@"gupTag"];
  f[@"defaults_sync"] = @(CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication));
  // keychain: a generic password in the default (file) keychain, then the data protection keychain
  NSDictionary *q = @{(id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"dev.cmux.gup-probe",
                      (id)kSecAttrAccount : self.tag, (id)kSecValueData : [self.tag dataUsingEncoding:NSUTF8StringEncoding]};
  SecItemDelete((__bridge CFDictionaryRef)q);
  f[@"kc_file"] = @(SecItemAdd((__bridge CFDictionaryRef)q, NULL));
  NSMutableDictionary *dp = [q mutableCopy];
  dp[(id)kSecUseDataProtectionKeychain] = @YES;
  f[@"kc_dataprotection"] = @(SecItemAdd((__bridge CFDictionaryRef)dp, NULL));
  SecKeychainRef kc = NULL;
  OSStatus ks = SecKeychainCopyDefault(&kc);
  f[@"kc_default_status"] = @(ks);
  if (ks == 0 && kc) {
    char path[1024]; UInt32 len = sizeof(path);
    if (SecKeychainGetPath(kc, &len, path) == 0) f[@"kc_default_path"] = [[NSString alloc] initWithBytes:path length:len encoding:NSUTF8StringEncoding];
    CFRelease(kc);
  }
  // pasteboard: does this account write the console user's general pasteboard?
  NSString *token = [NSString stringWithFormat:@"gup-%@-%d", self.tag, getpid()];
  [NSPasteboard.generalPasteboard clearContents];
  f[@"pb_write"] = @([NSPasteboard.generalPasteboard setString:token forType:NSPasteboardTypeString]);
  f[@"pb_token"] = token;
  [self write];
}
- (void)press:(id)sender {
  self.clicks++;
  self.window.title = [NSString stringWithFormat:@"gup %@: %ld", self.tag, self.clicks];
  [self write];
}
@end

static int app_main(int argc, const char **argv) {
  if (argc < 4) return 2;
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  GupApp *d = [GupApp new];
  d.tag = @(argv[2]);
  d.status = @(argv[3]);
  d.origin = NSMakePoint(argc > 4 ? atof(argv[4]) : 40, argc > 5 ? atof(argv[5]) : 60);
  NSApp.delegate = d;
  [NSApp run];
  return 0;
}

static int windows_main(pid_t pid) {
  CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary *w in (__bridge NSArray *)list) {
    if ([w[(id)kCGWindowOwnerPID] intValue] != pid) continue;
    CGRect r = CGRectZero;
    CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r);
    [out addObject:@{@"wid" : w[(id)kCGWindowNumber] ?: @0, @"layer" : w[(id)kCGWindowLayer] ?: @0,
                     @"onscreen" : w[(id)kCGWindowIsOnscreen] ?: @NO, @"x" : @(r.origin.x), @"y" : @(r.origin.y),
                     @"w" : @(r.size.width), @"h" : @(r.size.height)}];
  }
  if (list) CFRelease(list);
  printf("%s\n", json(@{@"pid" : @(pid), @"list_ok" : @(list != NULL), @"windows" : out}).UTF8String);
  return 0;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc < 2) return 2;
    if (!strcmp(argv[1], "now")) { printf("%.6f\n", now_s()); return 0; }
    if (!strcmp(argv[1], "since") && argc > 2) { printf("%.1f\n", (now_s() - atof(argv[2])) * 1000); return 0; }
    if (!strcmp(argv[1], "app")) return app_main(argc, argv);
    if (!strcmp(argv[1], "windows") && argc > 2) return windows_main(atoi(argv[2]));
    if (!strcmp(argv[1], "session")) { printf("%s\n", json(session()).UTF8String); return 0; }
    if (!strcmp(argv[1], "mem") && argc > 2) {
      struct rusage_info_v4 ri;
      if (proc_pid_rusage(atoi(argv[2]), RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) { printf("{\"ok\":false}\n"); return 0; }
      printf("{\"ok\":true,\"footprint\":%llu,\"resident\":%llu}\n", ri.ri_phys_footprint, ri.ri_resident_size);
      return 0;
    }
    return 2;
  }
}
OBJC

t_build=$(date +%s)
APP="$WORK/Gup.app"
mkdir -p "$APP/Contents/MacOS"
cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.cmux.gup-probe</string>
<key>CFBundleName</key><string>Gup</string>
<key>CFBundleExecutable</key><string>gup</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><false/>
</dict></plist>
PLIST
build_user=$(stat -f%Su /dev/console 2>/dev/null)
compile=(xcrun clang -fobjc-arc -O1 -o "$APP/Contents/MacOS/gup" "$WORK/gup.m" -framework AppKit
  -framework ApplicationServices -framework Security -framework CoreGraphics)
if [[ $EUID -eq 0 && -n "$build_user" && "$build_user" != root ]]; then
  chown -R "$build_user" "$WORK/Gup.app" "$WORK/gup.m"
  sudo -u "$build_user" "${compile[@]}" >"$WORK/build.log" 2>&1
else
  "${compile[@]}" >"$WORK/build.log" 2>&1
fi
if [[ ! -x "$APP/Contents/MacOS/gup" ]]; then
  say "{\"stage\":\"build\",\"ok\":false,\"log\":$(jstr "$(tail -20 "$WORK/build.log")")}"
  rm -rf "$WORK"; exit 4
fi
codesign -s - -f "$APP" >/dev/null 2>&1
ln -s "$APP/Contents/MacOS/gup" "$WORK/gup"
chmod -R a+rX "$WORK/Gup.app"
say "{\"stage\":\"build\",\"ok\":true,\"s\":$(( $(date +%s) - t_build ))}"

# ------------------------------------------------------------------ host, SIP, MDM, console session
cuser=$(stat -f%Su /dev/console 2>/dev/null)
cuid=$(id -u "$cuser" 2>/dev/null || echo 0)
mem_b=$(sysctl -n hw.memsize); ncpu=$(sysctl -n hw.ncpu)
sip=$(csrutil status 2>&1 | head -1)
mdm=$(profiles status -type enrollment 2>&1 | tr '\n' ' ')
fv=$(fdesetup status 2>&1 | head -1)
say "{\"stage\":\"host\",\"host\":$(jstr "$(hostname -s)"),\"os\":$(jstr "$(sw_vers -productVersion) $(sw_vers -buildVersion)"),\"chip\":$(jstr "$(sysctl -n machdep.cpu.brand_string)"),\"mem_gib\":$(( mem_b >> 30 )),\"ncpu\":$ncpu,\"euid\":$EUID,\"console_user\":$(jstr "$cuser"),\"console_uid\":$cuid,\"sip\":$(jstr "$sip"),\"mdm\":$(jstr "$mdm"),\"filevault\":$(jstr "$fv"),\"cgsession_exists\":$([[ -e '/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession' ]] && echo true || echo false),\"screensharing\":$(jstr "$(launchctl print-disabled system 2>/dev/null | grep -i screensharing | tr -s ' ' | tr '\n' ' ')")}"

if [[ "$cuser" == root || "$cuser" == loginwindow || -z "$cuser" ]]; then
  say "{\"stage\":\"console\",\"ok\":false,\"why\":\"no user is logged in on the console\"}"
  rm -rf "$WORK"; exit 4
fi

# as_console CMD: CMD in the console user's session as that user. as_pool U ROUTE CMD: as account U, in the console
# session (ROUTE console) or in U's own bootstrap (ROUTE own). Root only; a non-root run is already the console user.
as_console() { if [[ $EUID -eq 0 ]]; then launchctl asuser "$cuid" sudo -u "$cuser" -H -- "$@"; else "$@"; fi; }
# jout CMD: CMD's JSON line, or {} when it printed nothing (so a failed read never breaks the line around it).
jout() { local o; o=$("$@" 2>/dev/null | head -1); if [[ -n "$o" ]]; then printf '%s' "$o"; else printf '{}'; fi; }
as_pool() {
  local u="$1" route="$2" puid; shift 2
  puid=$(id -u "$u")
  if [[ "$route" == console ]]; then launchctl asuser "$cuid" sudo -u "$u" -H -- "$@"; else launchctl asuser "$puid" sudo -u "$u" -H -- "$@"; fi
}

# wait_status FILE SECONDS: until FILE exists (the app's window is up) or the deadline; 0 when it came.
wait_status() { local f="$1" end=$(( $(date +%s) + $2 )); while [[ ! -s "$f" && $(date +%s) -lt $end ]]; do sleep 0.2; done; [[ -s "$f" ]]; }
field() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

# cua_check TAG STATUSFILE: the console's CuaDriver (its daemon holds the console's grants) reads the app's
# window with a screenshot (ScreenCaptureKit) and its AX tree, then presses the button by AX; the app's own
# click count says whether the press arrived.
cua_check() {
  local tag="$1" st="$2" pid wid shot raw tok click_raw clicks t0 ms_state ms_click
  pid=$(field "$st" pid); wid=$(field "$st" wid)
  if [[ ! -x "$CUA" ]]; then say "{\"stage\":\"cua\",\"tag\":$(jstr "$tag"),\"ok\":false,\"why\":\"no CuaDriver.app\"}"; return; fi
  shot="$WORK/shots/$tag.png"; rm -f "$shot"
  t0=$(now)
  raw=$(as_console "$CUA" call get_window_state "{\"pid\":$pid,\"window_id\":$wid,\"include_accessibility_tree\":true,\"screenshot_out_file\":\"$shot\"}" 2>&1)
  ms_state=$(ms_since "$t0")
  tok=$(printf '%s' "$raw" | /usr/bin/python3 -I -c '
import json, sys
try:
    a = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
s = a.get("structuredContent") if isinstance(a.get("structuredContent"), dict) else a
for e in s.get("elements") or []:
    if e.get("role") == "AXButton" and "gup-press" in (str(e.get("label")) + str(e.get("title")) + str(e.get("identifier"))) and e.get("element_token"):
        print(e["element_token"]); break
' 2>/dev/null)
  click_raw=""; ms_click=-1
  if [[ -n "$tok" ]]; then
    t0=$(now)
    click_raw=$(as_console "$CUA" call click "{\"pid\":$pid,\"window_id\":$wid,\"element_token\":\"$tok\",\"action\":\"press\"}" 2>&1)
    local end=$(( $(date +%s) + 5 ))
    while [[ "$(field "$st" clicks)" == 0 && $(date +%s) -lt $end ]]; do sleep 0.05; done
    ms_click=$(ms_since "$t0")
  fi
  clicks=$(field "$st" clicks)
  local shot_bytes=0; [[ -s "$shot" ]] && shot_bytes=$(stat -f%z "$shot")
  say "{\"stage\":\"cua\",\"tag\":$(jstr "$tag"),\"pid\":${pid:-0},\"wid\":${wid:-0},\"shot_bytes\":$shot_bytes,\"state_ms\":${ms_state:-0},\"button_in_tree\":$([[ -n "$tok" ]] && echo true || echo false),\"click_ms\":${ms_click:--1},\"clicks\":${clicks:-0},\"state_raw\":$(jstr "${raw:0:300}"),\"click_raw\":$(jstr "${click_raw:0:300}")}"
}

if [[ -x "$CUA" ]]; then
  perms=$(as_console "$CUA" permissions status 2>&1 | head -6)
  if printf '%s' "$perms" | grep -qi 'daemon'; then
    # The host's own driver daemon is not up: start it the way mini-ops/cua-driver.sh says (it stays, the host's).
    as_console /usr/bin/open -n -g -a CuaDriver --args serve >/dev/null 2>&1
    end=$(( $(date +%s) + 15 ))
    while printf '%s' "$perms" | grep -qi 'daemon' && [[ $(date +%s) -lt $end ]]; do sleep 1; perms=$(as_console "$CUA" permissions status 2>&1 | head -6); done
  fi
  say "{\"stage\":\"cua-perms\",\"out\":$(jstr "$perms")}"
fi
say "{\"stage\":\"session\",\"as\":\"console-user\",\"out\":$(jout as_console "$WORK/gup" session)}"

# Baseline: the same app as the console user itself, through the same driver.
st="$WORK/status/base.json"
as_console "$APP/Contents/MacOS/gup" app base "$st" 40 60 >"$WORK/base.log" 2>&1 &
if wait_status "$st" 20; then
  base_pids=$(field "$st" pid)
  say "{\"stage\":\"app\",\"route\":\"console-user\",\"status\":$(cat "$st")}"
  say "{\"stage\":\"windows\",\"route\":\"console-user\",\"out\":$(jout as_console "$WORK/gup" windows "$base_pids")}"
  cua_check base "$st"
  say "{\"stage\":\"pasteboard\",\"route\":\"console-user\",\"console_reads\":$(jstr "$(as_console pbpaste 2>/dev/null)")}"
else
  say "{\"stage\":\"app\",\"route\":\"console-user\",\"ok\":false,\"log\":$(jstr "$(tail -5 "$WORK/base.log")")}"; failed=1
fi

# A full logged-in GUI session's own cost: the console user's processes (count, resident MB).
read -r c_n c_rss < <(ps -axo uid=,rss= | awk -v u="$cuid" '$1 == u {n++; r += $2} END {print n+0, int(r/1024)}')
say "{\"stage\":\"session-cost\",\"who\":\"console user (a full GUI login)\",\"procs\":$c_n,\"rss_mb\":$c_rss,\"top\":$(jstr "$(ps -axo uid=,rss=,comm= | awk -v u="$cuid" '$1 == u {print $2, $3}' | sort -rn | head -12 | awk '{n=split($2,p,"/"); printf "%s %dMB; ", p[n], $1/1024}')")}"

if [[ $EUID -ne 0 ]]; then
  [[ -n "${base_pids:-}" ]] && kill $base_pids 2>/dev/null
  say "{\"stage\":\"pool\",\"ok\":false,\"why\":\"not root: the pool stages (accounts) run under fleet-sudo HOST -f scripts/measure/gui-user-per-job.sh\"}"
  echo "GUP-SUMMARY console-session stages only (not root)"
  rm -rf "$WORK"; exit "$failed"
fi
trap cleanup EXIT INT TERM HUP

# ------------------------------------------------------------------ (b) TCC writes as root, SIP on or off
sys_db="/Library/Application Support/com.apple.TCC/TCC.db"
tcc_try() { /usr/bin/sqlite3 "$1" 'BEGIN IMMEDIATE; ROLLBACK;' 2>&1 && echo ok; }
say "{\"stage\":\"tcc\",\"db\":\"system\",\"read\":$(jstr "$(/usr/bin/sqlite3 "$sys_db" "select service||'|'||client||'|'||auth_value from access where service in ('kTCCServiceScreenCapture','kTCCServiceAccessibility','kTCCServicePostEvent','kTCCServiceListenEvent')" 2>&1 | tr '\n' ';')"),\"write\":$(jstr "$(tcc_try "$sys_db")")}"

# ------------------------------------------------------------------ (d) accounts: create, home, keychain
for (( i = 1; i <= pool_n; i++ )); do
  u=$(printf '%s%02d' "$PREFIX" "$i")
  if dscl . -read "/Users/$u" >/dev/null 2>&1; then
    if [[ "$(dscl . -read "/Users/$u" RealName 2>/dev/null | tail -1 | sed 's/^ *//; s/^RealName: //')" == "$MARK" ]]; then
      note "$u is left from an earlier run of this probe; removing it"; remove_account "$u"
    else
      say "{\"stage\":\"accounts\",\"ok\":false,\"why\":$(jstr "$u exists and is not this probe's; refusing")}"; exit 4
    fi
  fi
  if dscl . -search /Users UniqueID $(( UID0 + i )) 2>/dev/null | grep -q .; then
    say "{\"stage\":\"accounts\",\"ok\":false,\"why\":$(jstr "UID $(( UID0 + i )) is taken; refusing")}"; exit 4
  fi
done

for (( i = 1; i <= pool_n; i++ )); do
  u=$(printf '%s%02d' "$PREFIX" "$i")
  pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  t0=$(now)
  out=$(sysadminctl -addUser "$u" -fullName "$MARK" -UID $(( UID0 + i )) -password "$pw" -home "/Users/$u" -shell /bin/zsh 2>&1)
  add_ms=$(ms_since "$t0")
  if ! dscl . -read "/Users/$u" >/dev/null 2>&1; then
    say "{\"stage\":\"add\",\"user\":\"$u\",\"ok\":false,\"out\":$(jstr "$out")}"; failed=1; break
  fi
  created+=("$u")
  dscl . -create "/Users/$u" IsHidden 1
  home_after_add=$([[ -d "/Users/$u" ]] && echo true || echo false)
  t0=$(now); hout=$(createhomedir -c -u "$u" 2>&1); home_ms=$(ms_since "$t0")
  home_kb=$(du -sk "/Users/$u" 2>/dev/null | awk '{print $1}')
  t0=$(now)
  kout=$(as_pool "$u" console security create-keychain -p "$pw" login.keychain 2>&1 &&
         as_pool "$u" console security default-keychain -s login.keychain 2>&1 &&
         as_pool "$u" console security login-keychain -s login.keychain 2>&1)
  kc_rc=$?
  kc_ms=$(ms_since "$t0")
  tok=$(sysadminctl -secureTokenStatus "$u" 2>&1 | sed 's/.*Secure token is //' | head -1)
  unset pw
  say "{\"stage\":\"add\",\"user\":\"$u\",\"ok\":true,\"add_ms\":$add_ms,\"home_after_add\":$home_after_add,\"createhomedir_ms\":$home_ms,\"home_kb\":${home_kb:-0},\"keychain_ms\":$kc_ms,\"keychain_rc\":$kc_rc,\"secure_token\":$(jstr "$tok"),\"add_out\":$(jstr "$(printf '%s' "$out" | grep -v -i password | head -3)"),\"home_out\":$(jstr "$hout"),\"keychain_out\":$(jstr "$kout")}"
done
[[ ${#created[@]} -gt 0 ]] || { say "{\"stage\":\"pool\",\"ok\":false,\"why\":\"no account was created\"}"; exit 4; }
u1="${created[0]}"; uid1=$(id -u "$u1")

# ------------------------------------------------------------------ (b) the new account's own TCC.db
u_db="/Users/$u1/Library/Application Support/com.apple.TCC/TCC.db"
say "{\"stage\":\"tcc\",\"db\":\"user $u1\",\"exists\":$([[ -e "$u_db" ]] && echo true || echo false),\"write\":$(jstr "$( [[ -e "$u_db" ]] && tcc_try "$u_db" || echo 'no db yet')"),\"tccutil\":$(jstr "$(as_pool "$u1" console tccutil reset ScreenCapture dev.cmux.gup-probe 2>&1 | head -2)")}"

# ------------------------------------------------------------------ (a) routes for one account
say "{\"stage\":\"gui-domain\",\"user\":\"$u1\",\"print\":$(jstr "$(launchctl print "gui/$uid1" 2>&1 | head -3)")}"

say "{\"stage\":\"session\",\"as\":\"$u1 own bootstrap\",\"out\":$(jout as_pool "$u1" own "$WORK/gup" session)}"
st="$WORK/status/own.json"
t0=$(now)
as_pool "$u1" own "$APP/Contents/MacOS/gup" app own "$st" 480 60 >"$WORK/own.log" 2>&1 &
if wait_status "$st" 20; then
  say "{\"stage\":\"app\",\"route\":\"own\",\"user\":\"$u1\",\"spawn_to_status_ms\":$(ms_since "$t0"),\"status\":$(cat "$st")}"
  say "{\"stage\":\"windows\",\"route\":\"own\",\"out\":$(jout as_console "$WORK/gup" windows "$(field "$st" pid)")}"
  cua_check own "$st"
  kill "$(field "$st" pid)" 2>/dev/null
else
  say "{\"stage\":\"app\",\"route\":\"own\",\"user\":\"$u1\",\"ok\":false,\"log\":$(jstr "$(tail -8 "$WORK/own.log")")}"
fi
pids=$(ps -axo pid=,uid= | awk -v u="$uid1" '$2 == u {print $1}'); [[ -n "$pids" ]] && kill $pids 2>/dev/null

say "{\"stage\":\"session\",\"as\":\"$u1 in the console session\",\"out\":$(jout as_pool "$u1" console "$WORK/gup" session)}"
st="$WORK/status/console1.json"
t0=$(now)
as_pool "$u1" console "$APP/Contents/MacOS/gup" app console1 "$st" 480 60 >"$WORK/console1.log" 2>&1 &
if wait_status "$st" 20; then
  p=$(field "$st" pid)
  say "{\"stage\":\"app\",\"route\":\"console\",\"user\":\"$u1\",\"spawn_to_status_ms\":$(ms_since "$t0"),\"status\":$(cat "$st")}"
  say "{\"stage\":\"windows\",\"route\":\"console\",\"out\":$(jout as_console "$WORK/gup" windows "$p")}"
  cua_check console1 "$st"
  # isolation: where its writes went
  pref="/Users/$u1/Library/Preferences/dev.cmux.gup-probe.plist"
  cpref="/Users/$cuser/Library/Preferences/dev.cmux.gup-probe.plist"
  say "{\"stage\":\"isolation\",\"user\":\"$u1\",\"defaults_in_own_home\":$(jstr "$(field "$pref" gupTag) $(stat -f%Su "$pref" 2>/dev/null)"),\"defaults_in_console_home\":$(jstr "$(field "$cpref" gupTag)"),\"keychain_own\":$(jstr "$(as_pool "$u1" console security find-generic-password -s dev.cmux.gup-probe -a console1 2>&1 | grep -E 'keychain:|acct' | tr '\n' ' ')"),\"keychain_console\":$(jstr "$(as_console security find-generic-password -s dev.cmux.gup-probe -a console1 2>&1 | head -1)"),\"pasteboard_token\":$(jstr "$(field "$st" pb_token)"),\"console_pbpaste\":$(jstr "$(as_console pbpaste 2>/dev/null)"),\"own_route_pbpaste\":$(jstr "$(as_pool "$u1" own pbpaste 2>&1 | head -1)")}"
  kill "$p" 2>/dev/null
else
  say "{\"stage\":\"app\",\"route\":\"console\",\"user\":\"$u1\",\"ok\":false,\"log\":$(jstr "$(tail -8 "$WORK/console1.log")")}"; failed=1
fi
[[ -n "${base_pids:-}" ]] && kill $base_pids 2>/dev/null; base_pids=""

# ------------------------------------------------------------------ (c) density: k accounts' apps at once
host_mem() {  # used MB (active + wired + compressed), swap used MB, CPU idle % over 3 s
  local ps_b
  ps_b=$(sysctl -n hw.pagesize)
  vm_stat | awk -v p="$ps_b" '/Pages active/ {a=$3} /Pages wired/ {w=$4} /occupied by compressor/ {c=$5} END {printf "%d ", (a+w+c)*p/1048576}'
  sysctl -n vm.swapusage | awk '{print $6+0}' | tr '\n' ' '
  top -l 2 -n 0 -s 3 | awk '/CPU usage/ {i=$7} END {print i+0}'
}
read -r base_used base_swap base_idle < <(host_mem)
say "{\"stage\":\"density-base\",\"used_mb\":$base_used,\"swap_mb\":$base_swap,\"cpu_idle_pct\":$base_idle}"
IFS=, read -ra ks <<<"$ns"
for k in "${ks[@]}"; do
  (( k > ${#created[@]} )) && break
  rm -f "$WORK"/status/d*.json
  t0=$(now)
  for (( j = 0; j < k; j++ )); do
    as_pool "${created[$j]}" console "$APP/Contents/MacOS/gup" app "d$j" "$WORK/status/d$j.json" $(( 40 + (j % 4) * 440 )) $(( 260 + (j / 4) * 200 )) >/dev/null 2>&1 &
  done
  up=0; for (( j = 0; j < k; j++ )); do wait_status "$WORK/status/d$j.json" 30 && up=$(( up + 1 )); done
  all_ms=$(ms_since "$t0")
  ready=$(for (( j = 0; j < k; j++ )); do field "$WORK/status/d$j.json" ready_ms; done | sort -n | tr '\n' ',' | sed 's/,$//')
  sleep 5  # let per-account services the apps started settle before reading their cost
  read -r used swap idle < <(host_mem)
  per=""
  for (( j = 0; j < k; j++ )); do
    pu=$(id -u "${created[$j]}")
    read -r pn prss < <(ps -axo uid=,rss= | awk -v u="$pu" '$1 == u {n++; r += $2} END {print n+0, int(r/1024)}')
    per+="{\"user\":\"${created[$j]}\",\"procs\":$pn,\"rss_mb\":$prss,\"app\":$(jout "$WORK/gup" mem "$(field "$WORK/status/d$j.json" pid)")},"
  done
  say "{\"stage\":\"density\",\"k\":$k,\"up\":$up,\"all_up_ms\":$all_ms,\"ready_ms\":[${ready}],\"used_mb\":$used,\"used_delta_mb\":$(( used - base_used )),\"swap_mb\":$swap,\"cpu_idle_pct\":$idle,\"per_account\":[${per%,}],\"pool_procs\":$(jstr "$(ps -axo uid=,comm= | awk -v lo=$(( UID0 + 1 )) -v hi=$(( UID0 + 16 )) '$1 >= lo && $1 <= hi {n=split($2,p,"/"); print p[n]}' | sort | uniq -c | sort -rn | head -15 | awk '{printf "%s x%d; ", $2, $1}')")}"
  for (( j = 0; j < k; j++ )); do p=$(field "$WORK/status/d$j.json" pid); [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
done

# ------------------------------------------------------------------ (d) per-job reset and teardown
t0=$(now)
pids=$(ps -axo pid=,uid= | awk -v u="$uid1" '$2 == u {print $1}'); [[ -n "$pids" ]] && kill $pids 2>/dev/null
launchctl bootout "user/$uid1" >/dev/null 2>&1
rm -rf "/Users/$u1"; createhomedir -c -u "$u1" >/dev/null 2>&1
say "{\"stage\":\"reset\",\"user\":\"$u1\",\"ms\":$(ms_since "$t0"),\"home_back\":$([[ -d "/Users/$u1/Library" ]] && echo true || echo false)}"

for u in "${created[@]}"; do
  uid=$(id -u "$u")
  pids=$(ps -axo pid=,uid= | awk -v x="$uid" '$2 == x {print $1}'); [[ -n "$pids" ]] && kill $pids 2>/dev/null
  t0=$(now); launchctl bootout "user/$uid" >/dev/null 2>&1; bo_ms=$(ms_since "$t0")
  t0=$(now); dout=$(sysadminctl -deleteUser "$u" 2>&1); del_ms=$(ms_since "$t0")
  gone=$( dscl . -read "/Users/$u" >/dev/null 2>&1 && echo false || echo true )
  say "{\"stage\":\"delete\",\"user\":\"$u\",\"bootout_ms\":$bo_ms,\"delete_ms\":$del_ms,\"record_gone\":$gone,\"home_gone\":$([[ -d "/Users/$u" ]] && echo false || echo true),\"out\":$(jstr "$(printf '%s' "$dout" | head -2)")}"
done
cleanup   # anything the loop above left; also removes $WORK
echo "GUP-SUMMARY pool stages ran on $(hostname -s) as root; accounts made: $pool_n; all removed"
exit "$failed"
