#!/usr/bin/env python3
# Fake new cmux terminal: makes a pty pair, prints the slave path, logs what the adopted process writes, sends one input line.
import os, sys, time, select
m, s = os.openpty(); print(os.ttyname(s), flush=True)
log = open(sys.argv[1], "ab", buffering=0); t0 = time.time(); sent = False
while time.time() - t0 < float(sys.argv[2]):
    r,_,_ = select.select([m],[],[],0.5)
    if r: log.write(os.read(m, 4096))
    if not sent and time.time() - t0 > float(sys.argv[2]) - 6: os.write(m, b"typed-into-new-pty\n"); sent = True
