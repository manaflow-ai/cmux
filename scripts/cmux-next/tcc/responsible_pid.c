// Prints "<pid> <responsible pid>" for each pid argument: the process macOS
// TCC (privacy permissions) charges for that process's requests.
// responsibility_get_pid_responsible_for_pid is the libsystem call Chromium
// itself uses (base/process/process_info_mac.mm).
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>

extern pid_t responsibility_get_pid_responsible_for_pid(pid_t);

int main(int argc, char** argv) {
  for (int i = 1; i < argc; i++) {
    pid_t pid = (pid_t)atoi(argv[i]);
    printf("%d %d\n", pid, responsibility_get_pid_responsible_for_pid(pid));
  }
  return 0;
}
