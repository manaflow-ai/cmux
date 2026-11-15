#!/bin/bash
# watchdog.sh : keep the host's free disk >= 25 GB. When it drops below, save the guest's results
# (~/truth-out, without cell dirs) to ~/truth-evals/saved/, then stop and delete every truth-* VM.
cd ~/truth-evals
while true; do
  free=$(df -g / | tail -1 | awk '{print $4}')
  if [ "$free" -lt 25 ]; then
    echo "$(date) free ${free} GB: saving and deleting VMs" >> watchdog.log
    mkdir -p saved
    for vm in $(bin/tart list 2>/dev/null | awk '/truth-/{print $2}'); do
      if bin/tart list | grep -q "$vm.*running"; then
        ./gs.sh $vm 'pkill -f truthmatrix; pkill -f "cueval run"; cd ~ && tar czf /tmp/truth-out.tgz --exclude cells --exclude "*.sock" --exclude "*.mov" truth-out' 2>>watchdog.log
        ./gcp.sh $vm -from /tmp/truth-out.tgz saved/$vm-$(date +%H%M).tgz 2>>watchdog.log
        bin/tart stop $vm
      fi
      bin/tart delete $vm
    done
    pkill -f "relay.py 192.168.64.1"
    echo "$(date) done, free $(df -g / | tail -1 | awk '{print $4}') GB" >> watchdog.log
    touch WATCHDOG-FIRED
    exit 0
  fi
  sleep 30
done
