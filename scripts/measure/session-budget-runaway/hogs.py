import os, sys, time, threading, signal
kind = sys.argv[1]
if kind == "mem":
    target = int(sys.argv[2]) << 30; got = []; t0 = time.time()
    try:
        while sum(len(x) for x in got) < target:
            b = bytearray(256 << 20); b[::4096] = b"\1" * (len(b) // 4096); got.append(b)
            print(f"mem {sum(len(x) for x in got) >> 20} MB {time.time()-t0:.1f}s", flush=True)
        time.sleep(float(sys.argv[3]))
    except MemoryError: print("MemoryError", flush=True)
elif kind == "cpu":
    n = int(sys.argv[2]); d = float(sys.argv[3])
    import multiprocessing as mp
    def spin(d):
        e = time.time() + d
        while time.time() < e: pass
    ps = [mp.Process(target=spin, args=(d,)) for _ in range(n)]
    [p.start() for p in ps]; [p.join() for p in ps]
elif kind == "fork":
    cap = int(sys.argv[2]); hold = float(sys.argv[3]); kids = []; fails = 0
    for i in range(cap):
        try:
            pid = os.fork()
            if pid == 0: time.sleep(hold); os._exit(0)
            kids.append(pid)
        except OSError: fails += 1; break
    print(f"forked {len(kids)} then {'EAGAIN' if fails else 'cap'}", flush=True)
    for k in kids: os.waitpid(k, 0)
