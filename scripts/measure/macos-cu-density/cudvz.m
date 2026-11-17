// cudvz: macOS guests under Virtualization.framework, booted from Lume VM folders
// (scripts/measure/macos-cu-density.sh). Never more than two macOS VMs run at once (licence 2B(iii)).
//
//   cudvz cycle MEM_MB CPUS STATE_DIR DIR_A DIR_B DIR_C
//
// DIR_x is a stopped Lume VM folder (config.json with hardwareModel and machineIdentifier in base64,
// disk.img, nvram.bin). Steps, one JSON line each:
//   boot A                        start to the guest's sshd banner on its NAT address
//   boot B                        two running
//   save A (x3 with restores)     pause + saveMachineStateTo, file size; the first plain, the rest with
//                                 a latency-critical activity and IOPOL_IMPORTANT (the forum's speed-up)
//   boot C with A saved           does a saved VM still hold one of the two slots? (two running if not)
//   stop C, restore A             restoreMachineStateFrom + resume to the sshd banner
//   host RAM                      footprint and resident of each VM's com.apple.Virtualization.VirtualMachine
// Signed ad hoc with com.apple.security.virtualization.
#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>
#import <arpa/inet.h>
#import <libproc.h>
#import <mach/mach_time.h>
#import <netinet/in.h>
#import <sys/resource.h>
#import <sys/socket.h>
#import <sys/time.h>

static double now_s(void) {
  static mach_timebase_info_data_t tb;
  if (tb.denom == 0) mach_timebase_info(&tb);
  return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}
static void emit(NSDictionary *o) {
  NSData *d = nil;
  @try { d = [NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingSortedKeys error:nil]; } @catch (NSException *e) { d = nil; }
  printf("%s\n", d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding].UTF8String : o.description.UTF8String);
  fflush(stdout);
}
static id nn(id v) { return v ? v : [NSNull null]; }
static NSDictionary *errd(NSError *e) {
  if (!e) return (id)[NSNull null];
  return @{@"domain": e.domain, @"code": @(e.code), @"text": e.localizedDescription ?: @""};
}

@interface Guest : NSObject
@property(strong) NSString *name, *dir, *mac;
@property(strong) VZVirtualMachineConfiguration *config;
@property(strong) VZVirtualMachine *vm;
@property(strong) dispatch_queue_t q;
@end
@implementation Guest
@end

static NSString *norm_mac(NSString *m) {
  NSMutableArray *parts = [NSMutableArray array];
  for (NSString *p in [m.lowercaseString componentsSeparatedByString:@":"]) {
    NSString *s = p;
    while (s.length > 1 && [s hasPrefix:@"0"]) s = [s substringFromIndex:1];
    [parts addObject:s];
  }
  return [parts componentsJoinedByString:@":"];
}
static NSString *lease_ip(NSString *mac) {
  NSString *db = [NSString stringWithContentsOfFile:@"/var/db/dhcpd_leases" encoding:NSUTF8StringEncoding error:nil];
  if (!db) return nil;
  NSString *want = norm_mac(mac);
  for (NSString *block in [db componentsSeparatedByString:@"}"]) {
    NSString *ip = nil, *hw = nil;
    for (NSString *raw in [block componentsSeparatedByString:@"\n"]) {
      NSString *l = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      if ([l hasPrefix:@"ip_address="]) ip = [l substringFromIndex:11];
      if ([l hasPrefix:@"hw_address="]) { NSRange r = [l rangeOfString:@","]; if (r.location != NSNotFound) hw = [l substringFromIndex:r.location + 1]; }
    }
    if (ip && hw && [norm_mac(hw) isEqualToString:want]) return ip;
  }
  return nil;
}
// The guest answers when its sshd sends a banner: a process started in the guest for us.
static BOOL ssh_banner(NSString *ip, double timeout) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return NO;
  struct timeval tv = {(int)timeout, (int)((timeout - (int)timeout) * 1e6)};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(22)};
  inet_pton(AF_INET, ip.UTF8String, &a.sin_addr);
  BOOL ok = NO;
  if (connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0) {
    char buf[8] = {0};
    ok = recv(fd, buf, 4, MSG_WAITALL) == 4 && !memcmp(buf, "SSH-", 4);
  }
  close(fd);
  return ok;
}
static double wait_guest(Guest *g, double timeout, NSString **ipOut) {
  double t = now_s();
  while (now_s() - t < timeout) {
    NSString *ip = lease_ip(g.mac);
    if (ip && ssh_banner(ip, 1.0)) { if (ipOut) *ipOut = ip; return now_s() - t; }
    usleep(200000);
  }
  return -1;
}

static VZVirtualMachineConfiguration *make_config(Guest *g, uint64_t memMB, int cpus, NSError **err) {
  NSData *raw = [NSData dataWithContentsOfFile:[g.dir stringByAppendingPathComponent:@"config.json"]];
  NSDictionary *cfg = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:err] : nil;
  if (!cfg) return nil;
  NSData *hw = [[NSData alloc] initWithBase64EncodedString:cfg[@"hardwareModel"] ?: @"" options:0];
  NSData *mid = [[NSData alloc] initWithBase64EncodedString:cfg[@"machineIdentifier"] ?: @"" options:0];
  VZMacPlatformConfiguration *p = [[VZMacPlatformConfiguration alloc] init];
  p.hardwareModel = hw ? [[VZMacHardwareModel alloc] initWithDataRepresentation:hw] : nil;
  p.machineIdentifier = mid ? [[VZMacMachineIdentifier alloc] initWithDataRepresentation:mid] : nil;
  if (!p.hardwareModel || !p.machineIdentifier) {
    if (err) *err = [NSError errorWithDomain:@"cudvz" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"config.json keys %@", cfg.allKeys]}];
    return nil;
  }
  p.auxiliaryStorage = [[VZMacAuxiliaryStorage alloc] initWithURL:[NSURL fileURLWithPath:[g.dir stringByAppendingPathComponent:@"nvram.bin"]]];
  VZVirtualMachineConfiguration *c = [[VZVirtualMachineConfiguration alloc] init];
  c.platform = p;
  c.bootLoader = [[VZMacOSBootLoader alloc] init];
  c.CPUCount = cpus;
  c.memorySize = memMB << 20;
  VZMacGraphicsDeviceConfiguration *gr = [[VZMacGraphicsDeviceConfiguration alloc] init];
  gr.displays = @[ [[VZMacGraphicsDisplayConfiguration alloc] initWithWidthInPixels:1920 heightInPixels:1080 pixelsPerInch:80] ];
  c.graphicsDevices = @[ gr ];
  VZDiskImageStorageDeviceAttachment *disk =
      [[VZDiskImageStorageDeviceAttachment alloc] initWithURL:[NSURL fileURLWithPath:[g.dir stringByAppendingPathComponent:@"disk.img"]] readOnly:NO error:err];
  if (!disk) return nil;
  c.storageDevices = @[ [[VZVirtioBlockDeviceConfiguration alloc] initWithAttachment:disk] ];
  VZVirtioNetworkDeviceConfiguration *net = [[VZVirtioNetworkDeviceConfiguration alloc] init];
  net.attachment = [[VZNATNetworkDeviceAttachment alloc] init];
  // A MAC of our own per folder (Lume's clones may share one), kept across save and restore.
  NSString *macFile = [g.dir stringByAppendingPathComponent:@"cud-mac.txt"];
  NSString *mac = [[NSString stringWithContentsOfFile:macFile encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!mac.length) { mac = [VZMACAddress randomLocallyAdministeredAddress].string; [mac writeToFile:macFile atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
  net.MACAddress = [[VZMACAddress alloc] initWithString:mac];
  g.mac = mac;
  c.networkDevices = @[ net ];
  c.keyboards = @[ [[VZMacKeyboardConfiguration alloc] init] ];
  c.pointingDevices = @[ [[VZMacTrackpadConfiguration alloc] init] ];
  c.entropyDevices = @[ [[VZVirtioEntropyDeviceConfiguration alloc] init] ];
  c.memoryBalloonDevices = @[ [[VZVirtioTraditionalMemoryBalloonDeviceConfiguration alloc] init] ];
  if (![c validateWithError:err]) return nil;
  if (![c validateSaveRestoreSupportWithError:err]) return nil;
  return c;
}

// Runs op on the VM's queue and waits for its completion handler.
static NSError *on_vm(Guest *g, void (^op)(void (^done)(NSError *)), double timeout) {
  __block NSError *out = nil;
  dispatch_semaphore_t s = dispatch_semaphore_create(0);
  dispatch_async(g.q, ^{ op(^(NSError *e) { out = e; dispatch_semaphore_signal(s); }); });
  if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))))
    return [NSError errorWithDomain:@"cudvz" code:2 userInfo:@{NSLocalizedDescriptionKey: @"timed out"}];
  return out;
}
static void fresh_vm(Guest *g) {
  dispatch_sync(g.q, ^{ g.vm = [[VZVirtualMachine alloc] initWithConfiguration:g.config queue:g.q]; });
}

static BOOL running(Guest *g) {
  __block BOOL r = NO;
  dispatch_sync(g.q, ^{ r = g.vm && (g.vm.state == VZVirtualMachineStateRunning || g.vm.state == VZVirtualMachineStatePaused); });
  return r;
}

static NSDictionary *boot(Guest *g) {
  fresh_vm(g);
  double t = now_s();
  NSError *e = on_vm(g, ^(void (^done)(NSError *)) { [g.vm startWithCompletionHandler:^(NSError *err) { done(err); }]; }, 60);
  double started = now_s() - t;
  if (e) return @{@"vm": g.name, @"ok": @NO, @"start_s": @(started), @"error": errd(e)};
  NSString *ip = nil;
  double up = wait_guest(g, 420, &ip);
  return @{@"vm": g.name, @"ok": @(up >= 0), @"start_s": @(started), @"to_sshd_banner_s": @(up >= 0 ? now_s() - t : -1), @"ip": nn(ip)};
}
static NSDictionary *stop(Guest *g) {
  double t = now_s();
  NSError *e = on_vm(g, ^(void (^done)(NSError *)) { [g.vm stopWithCompletionHandler:^(NSError *err) { done(err); }]; }, 60);
  dispatch_sync(g.q, ^{ g.vm = nil; });
  return @{@"vm": g.name, @"stop_s": @(now_s() - t), @"error": errd(e)};
}
static NSDictionary *save(Guest *g, NSString *path, BOOL boost) {
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  id activity = nil;
  if (boost) {
    activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityLatencyCritical | NSActivityUserInitiated reason:@"cudvz save"];
    setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_IMPORTANT);
  }
  double t = now_s();
  NSError *e = on_vm(g, ^(void (^done)(NSError *)) { [g.vm pauseWithCompletionHandler:^(NSError *err) { done(err); }]; }, 60);
  double paused = now_s() - t;
  if (!e) e = on_vm(g, ^(void (^done)(NSError *)) { [g.vm saveMachineStateToURL:[NSURL fileURLWithPath:path] completionHandler:^(NSError *err) { done(err); }]; }, 600);
  double saved = now_s() - t;
  NSDictionary *st = stop(g);
  if (activity) [[NSProcessInfo processInfo] endActivity:activity];
  setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_DEFAULT);
  unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
  return @{@"vm": g.name, @"boost": @(boost), @"pause_s": @(paused), @"pause_and_save_s": @(saved), @"state_mb": @(size >> 20),
           @"mb_per_s": @(saved > 0 ? (size >> 20) / saved : 0), @"stop_after_save": st, @"error": errd(e)};
}
static NSDictionary *restore(Guest *g, NSString *path, BOOL boost) {
  id activity = nil;
  if (boost) {
    activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityLatencyCritical | NSActivityUserInitiated reason:@"cudvz restore"];
    setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_IMPORTANT);
  }
  fresh_vm(g);
  double t = now_s();
  NSError *e = on_vm(g, ^(void (^done)(NSError *)) { [g.vm restoreMachineStateFromURL:[NSURL fileURLWithPath:path] completionHandler:^(NSError *err) { done(err); }]; }, 600);
  double restored = now_s() - t;
  if (!e) e = on_vm(g, ^(void (^done)(NSError *)) { [g.vm resumeWithCompletionHandler:^(NSError *err) { done(err); }]; }, 60);
  double resumed = now_s() - t;
  if (activity) [[NSProcessInfo processInfo] endActivity:activity];
  setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_DEFAULT);
  if (e) return @{@"vm": g.name, @"ok": @NO, @"restore_s": @(restored), @"error": errd(e)};
  NSString *ip = nil;
  double up = wait_guest(g, 120, &ip);
  return @{@"vm": g.name, @"ok": @(up >= 0), @"boost": @(boost), @"restore_s": @(restored), @"restore_and_resume_s": @(resumed),
           @"to_sshd_banner_s": @(up >= 0 ? now_s() - t : -1)};
}

static NSArray *vz_processes(void) {
  int n = proc_listallpids(NULL, 0);
  pid_t *pids = calloc(n + 64, sizeof(pid_t));
  n = proc_listallpids(pids, (n + 64) * sizeof(pid_t));
  NSMutableArray *out = [NSMutableArray array];
  for (int i = 0; i < n; i++) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pids[i], path, sizeof(path)) <= 0 || !strstr(path, "com.apple.Virtualization.VirtualMachine")) continue;
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) continue;
    [out addObject:@{@"pid": @(pids[i]), @"footprint_mb": @(ri.ri_phys_footprint >> 20), @"resident_mb": @(ri.ri_resident_size >> 20)}];
  }
  free(pids);
  return out;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc < 8 || strcmp(argv[1], "cycle")) {
      fprintf(stderr, "usage: cudvz cycle MEM_MB CPUS STATE_DIR DIR_A DIR_B DIR_C\n");
      return 2;
    }
    uint64_t mem = strtoull(argv[2], NULL, 10);
    int cpus = atoi(argv[3]);
    NSString *stateDir = @(argv[4]);
    [[NSFileManager defaultManager] createDirectoryAtPath:stateDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray<Guest *> *gs = [NSMutableArray array];
    NSArray *names = @[ @"A", @"B", @"C" ];
    for (int i = 0; i < 3; i++) {
      Guest *g = [Guest new];
      g.name = names[i];
      g.dir = @(argv[5 + i]);
      g.q = dispatch_queue_create([NSString stringWithFormat:@"cudvz.%@", g.name].UTF8String, DISPATCH_QUEUE_SERIAL);
      NSError *e = nil;
      g.config = make_config(g, mem, cpus, &e);
      if (!g.config) { emit(@{@"step": @"config", @"vm": g.name, @"ok": @NO, @"error": errd(e)}); return 1; }
      [gs addObject:g];
    }
    emit(@{@"step": @"config", @"ok": @YES, @"mem_mb": @(mem), @"cpus": @(cpus), @"save_restore_supported": @YES,
           @"max_cpus": @(VZVirtualMachineConfiguration.maximumAllowedCPUCount)});
    Guest *A = gs[0], *B = gs[1], *C = gs[2];
    NSString *stateA = [stateDir stringByAppendingPathComponent:@"A.vzvmsave"];
    NSDictionary *r = boot(A);
    emit(@{@"step": @"boot A (1 running)", @"result": r});
    if (![r[@"ok"] boolValue]) return 1;
    sleep(30);  // let the login session settle before measuring RAM and saving
    emit(@{@"step": @"host RAM, A idle 30 s after boot", @"vz_processes": vz_processes()});
    r = boot(B);
    emit(@{@"step": @"boot B (2 running)", @"result": r});
    sleep(20);
    emit(@{@"step": @"host RAM, A and B", @"vz_processes": vz_processes()});
    emit(@{@"step": @"save A (plain), B running", @"result": save(A, stateA, NO)});
    emit(@{@"step": @"host RAM, A saved", @"vz_processes": vz_processes()});
    // Two running would be B and C; a refusal here means a saved VM still holds a slot.
    if (running(A)) {  // never a third: A must be stopped before C starts
      emit(@{@"step": @"A still running after save; stopping everything", @"stop_A": stop(A), @"stop_B": stop(B)});
      return 1;
    }
    r = boot(C);
    emit(@{@"step": @"boot C with A saved and B running (does a saved VM hold a slot?)", @"result": r});
    if (running(C)) emit(@{@"step": @"stop C", @"result": stop(C)});
    if (running(C)) {  // never a third: C must be stopped before A comes back
      emit(@{@"step": @"C still running; stopping everything", @"stop_C": stop(C), @"stop_B": stop(B)});
      return 1;
    }
    for (int rep = 1; rep <= 3; rep++) {
      BOOL boost = rep > 1;
      emit(@{@"step": [NSString stringWithFormat:@"restore A #%d, B running", rep], @"result": restore(A, stateA, boost)});
      if (!running(A)) break;
      if (rep < 3) emit(@{@"step": [NSString stringWithFormat:@"save A #%d (boost)", rep + 1], @"result": save(A, stateA, YES)});
    }
    emit(@{@"step": @"host RAM at the end", @"vz_processes": vz_processes()});
    if (running(A)) emit(@{@"step": @"stop A", @"result": stop(A)});
    if (running(B)) emit(@{@"step": @"stop B", @"result": stop(B)});
    [[NSFileManager defaultManager] removeItemAtPath:stateA error:nil];
    return 0;
  }
}
