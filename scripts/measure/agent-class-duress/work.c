// One tool job of an agent's turn, as a build step: a fixed amount of CPU work, then uncached
// reads of FILES 64 KiB files (F_NOCACHE, so the disk policy counts). Usage: work ITERS DIR FILES
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc < 4) return 2;
  long n = atol(argv[1]);
  int files = atoi(argv[3]);
  volatile unsigned long x = 88172645463325252UL;
  for (long i = 0; i < n; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; }
  static char buf[65536];
  char path[4096];
  for (int i = 1; i <= files; i++) {
    snprintf(path, sizeof path, "%s/f%d", argv[2], i);
    int fd = open(path, O_RDONLY);
    if (fd < 0) continue;
    fcntl(fd, F_NOCACHE, 1);
    while (read(fd, buf, sizeof buf) > 0) {}
    close(fd);
  }
  return 0;
}
