#!/bin/bash
# phase2.sh : on mini-5 after phase 1: bg-fix demo video; rewrite helper back; Aside arm (d); agent tier (a); demo videos
cd ~/truth-evals
CELLS=click_el_checkbox,click_px_checkbox,canvas_click_px,menu_disabled_item,popover_button,menu_submenu
bash demo.sh truth-1 cmux-cu demo-bgfix-lab lab $CELLS bg 150 > demo1.log 2>&1
bash demo.sh truth-1 cmux-cu demo-bgfix-safari safari set_value,click_px fg 120 >> demo1.log 2>&1
bash setup-rewrite.sh truth-1 > phase2-setup.log 2>&1
bash demo.sh truth-1 cmux-cu demo-rewrite-lab lab $CELLS bg 150 > demo2.log 2>&1
bash demo.sh truth-1 cmux-cu demo-rewrite-safari safari set_value,click_px fg 120 >> demo2.log 2>&1
bash demo.sh truth-1 cua-driver-0.38.0 demo-cua-lab lab $CELLS bg 150 >> demo2.log 2>&1
bash setup-aside.sh truth-1 > phase2-aside.log 2>&1
./gs.sh truth-1 "mkdir -p ~/truth-out; cd ~/cu && ./gr.sh -t 30000 ./cuenv2.sh python3 /Users/admin/cu/truth/truthmatrix.py --arm aside --reps 3 --out /Users/admin/truth-out/d-aside > /Users/admin/truth-out/d-aside.log 2>&1; echo rc=\$?" > d-aside.log 2>&1
bash demo.sh truth-1 aside demo-aside-lab lab $CELLS bg 200 >> demo2.log 2>&1
./gs.sh truth-1 "cd ~/cu && ./gr.sh -t 40000 ./cuenv2.sh python3 -m cueval run --agent codex --model gpt-6.1-sol --trials 3 --split all --arms cmux-cu,cua-driver-0.38.0 --prereg /Users/admin/cu/evals/computer-use/macos/prereg/prereg-agent-a.json --out /Users/admin/truth-out/agent-a > /Users/admin/truth-out/agent-a.log 2>&1; echo rc=\$?" > agent-a.log 2>&1
echo PHASE2-DONE > phase2.done
