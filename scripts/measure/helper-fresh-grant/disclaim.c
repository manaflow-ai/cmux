// Starts argv[1..] as its own responsible process (as the cmux daemon starts the Screen Sharing helper), prints
// its pid and exits: macOS then checks the started program's own privacy grants, not this launcher's.
// helper-fresh-grant.sh part c. Open file descriptors (the host's --token-fd 3) are inherited.
#include <spawn.h>
#include <stdio.h>
#include <sys/types.h>

extern char **environ;
extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim);

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: disclaim PROGRAM [ARGS...]\n");
    return 2;
  }
  posix_spawnattr_t attrs;
  posix_spawnattr_init(&attrs);
  if (responsibility_spawnattrs_setdisclaim(&attrs, 1) != 0) {
    fprintf(stderr, "disclaim: responsibility_spawnattrs_setdisclaim failed\n");
    return 1;
  }
  pid_t pid;
  int rc = posix_spawn(&pid, argv[1], NULL, &attrs, argv + 1, environ);
  if (rc != 0) {
    fprintf(stderr, "disclaim: posix_spawn %s: %d\n", argv[1], rc);
    return 127;
  }
  printf("%d\n", (int)pid);
  return 0;
}
