# punch.py FILE: deallocate all-zero 1 MiB blocks in place (APFS F_PUNCHHOLE); content is unchanged
import fcntl, os, struct, sys
F_PUNCHHOLE = 99
CH = 1 << 20
z = bytes(CH)
fd = os.open(sys.argv[1], os.O_RDWR)
size = os.fstat(fd).st_size
off = 0; run = None; freed = 0
def punch(a, b):
    global freed
    fcntl.fcntl(fd, F_PUNCHHOLE, struct.pack("IIqq", 0, 0, a, b - a)); freed += b - a
while off < size:
    b = os.pread(fd, CH, off)
    if b == z[:len(b)] and len(b) == CH:
        run = off if run is None else run
    else:
        if run is not None: punch(run, off); run = None
    off += len(b)
if run is not None: punch(run, off - (off % 4096))
os.close(fd)
print("freed GB", round(freed / 1e9, 1))
