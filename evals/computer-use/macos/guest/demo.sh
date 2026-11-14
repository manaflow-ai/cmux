#!/bin/bash
# demo.sh VM ARM NAME APPS ACTIONS SCENES SECS : record the guest screen while truthmatrix replays the given cells once
# (rep 9, unscored), then make a small mp4 on the host (~/truth-evals/videos/NAME.mp4)
vm=$1 arm=$2 name=$3 apps=$4 actions=$5 scenes=$6 secs=${7:-150}
cd ~/truth-evals && mkdir -p videos
./gs.sh $vm "mkdir -p ~/truth-out; rm -f ~/truth-out/$name.mov; cd ~/cu && ./gr.sh -b screencapture -x -v -V $secs ~/truth-out/$name.mov >/dev/null; sleep 2; ./gr.sh -t 1200 ./cuenv2.sh python3 /Users/admin/cu/truth/truthmatrix.py --arm $arm --apps $apps --actions $actions --scenes $scenes --reps 1 --rep-start 9 --out /Users/admin/truth-out/$name > ~/truth-out/$name.log 2>&1; for i in \$(seq 1 $secs); do pgrep -x screencapture >/dev/null || break; sleep 1; done; ls -la ~/truth-out/$name.mov"
./gcp.sh $vm -from /Users/admin/truth-out/$name.mov videos/$name.mov
/opt/homebrew/bin/ffmpeg -loglevel error -y -i videos/$name.mov -vf "scale=1152:-2,fps=15" -c:v libx264 -crf 30 -preset slow -pix_fmt yuv420p -an videos/$name.mp4 && ls -la videos/$name.mp4
