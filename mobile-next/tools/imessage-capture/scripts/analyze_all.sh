#!/bin/bash
# Run every numeric track used in IMESSAGE-SPEC.md. Output: $ROOT/an/results.txt
ROOT="${CNM_ROOT:-$HOME/cnm/imessage}"
cd "$ROOT"
PY="${PY:-$ROOT/venv/bin/python}"
S="$(cd "$(dirname "$0")" && pwd)"
T="$PY $S/track2.py"
L="$PY $S/lum.py"
{
echo "=== s2-push: transcript first bubble x0 (card slides in from x=402)"; $T an/s2-push/frames --pred green --thresh 40 --region 0,180,402,280 --pick highest --prop x0 --start 5 --end 30 --from-value 533.33
echo "=== s2-push: list row avatar x0 (parallax under the card)"; $T an/s2-push/frames --pred blue --thresh 20 --region 0,190,130,260 --pick leftmost --prop x0 --min-px 20
echo "=== s2-push: dim of list behind card (sample x=10..60,y=600..700)"; $L an/s2-push/frames 10,600,60,700 1 30
echo "=== s2-push-b (received-first chat)"; $T an/s2-push-b/frames --pred blue --thresh 20 --region 0,190,130,260 --pick leftmost --prop x0 --quiet --min-px 20
echo "=== s2-back-button: transcript bubble x0"; $T an/s2-back-button/frames --pred green --thresh 40 --region 0,180,402,280 --pick highest --prop x0 --bezier
echo "=== s2-back-button: list avatar x0"; $T an/s2-back-button/frames --pred blue --thresh 20 --region 0,190,130,260 --pick leftmost --prop x0 --quiet --min-px 20
echo "=== s2-edge-partial: transcript bubble x0 (finger to x=130 then release => cancel)"; $T an/s2-edge-partial/frames --pred green --thresh 40 --region 0,180,402,280 --pick highest --prop x0
echo "=== s2-edge-complete: transcript bubble x0 (fast flick to x=400 => pop)"; $T an/s2-edge-complete/frames --pred green --thresh 40 --region 0,180,402,280 --pick highest --prop x0
echo "=== s2-push-dark"; $T an/s2-push-dark/frames --pred green --thresh 40 --region 0,180,402,280 --pick highest --prop x0 --quiet --start 5 --end 30 --from-value 533.33
echo "=== s3-keyboard-rise: composer '+' glyph top (dark) y0"; $T an/s3-keyboard-rise/frames --pred dark --thresh 90 --region 8,300,70,874 --pick lowest --prop y0 --bezier
echo "=== s3-send-1 (green bubble lowest component, region above composer)"; $T an/s3-send-1/frames --pred green --thresh 30 --region 0,400,402,560 --pick lowest --prop y1 --first 1 --last 60
echo "=== s3-send-1 scale phase w"; $T an/s3-send-1/frames --pred green --thresh 30 --region 0,400,402,505 --pick lowest --prop w --quiet --first 21 --last 70 --start 21 --end 50
echo "=== s3-send-1 rise phase y1"; $T an/s3-send-1/frames --pred green --thresh 30 --region 0,400,402,505 --pick lowest --prop y1 --quiet --first 21 --last 70 --start 21 --end 50
echo "=== s3-send-1 previous bubble ('See you at 7') y0 scroll-up"; $T an/s3-send-1/frames --pred green --thresh 30 --region 0,380,402,440 --pick lowest --prop y0 --quiet
echo "=== s3-send-2-multiline"; $T an/s3-send-2-multiline/frames --pred green --thresh 30 --region 0,150,402,560 --pick lowest --prop y1
echo "=== s3-send-4-tail"; $T an/s3-send-4-tail/frames --pred green --thresh 30 --region 0,300,402,560 --pick lowest --prop y1
echo "=== s3-multiline-grow: field text top y0 (dark text in composer)"; $T an/s3-multiline-grow/frames --pred dark --thresh 90 --region 80,250,330,530 --pick union --prop y0 --quiet
echo "=== s3-timestamp-drag: lowest sent bubble x1"; $T an/s3-timestamp-drag/frames --pred green --thresh 30 --region 0,150,402,800 --pick lowest --prop x1
echo "=== s5-kb-partial-drag: '+' y0"; $T an/s5-kb-partial-drag/frames --pred dark --thresh 90 --region 8,300,70,874 --pick lowest --prop y0
echo "=== s5-kb-dismiss-drag: '+' y0"; $T an/s5-kb-dismiss-drag/frames --pred dark --thresh 90 --region 8,300,70,874 --pick lowest --prop y0
echo "=== s1-swipe-left: trash circle (red) bbox"; $T an/s1-swipe-left/frames --pred color:255,56,60 --thresh 60 --region 200,150,402,280 --pick largest --prop w --min-px 3
echo "=== s1-swipe-left: mute circle (purple) bbox"; $T an/s1-swipe-left/frames --pred blue --thresh 40 --region 200,150,402,280 --pick largest --prop w --quiet --min-px 3
echo "=== s1-swipe-left: row avatar x0"; $T an/s1-swipe-left/frames --pred blue --thresh 20 --region 0,150,200,260 --pick leftmost --prop x0 --min-px 20
echo "=== s1-swipe-left-close: trash w"; $T an/s1-swipe-left-close/frames --pred color:255,56,60 --thresh 60 --region 150,150,402,280 --pick largest --prop w --min-px 3
echo "=== s1-swipe-right: unread circle (blue) w"; $T an/s1-swipe-right/frames --pred blue --thresh 60 --region 0,150,120,280 --pick largest --prop w --min-px 3
echo "=== s1-pull-drag: large title dark bbox"; $T an/s1-pull-drag/frames --pred dark --thresh 90 --region 0,60,402,175 --pick largest --prop h
echo "=== s1-pull-release: large title dark bbox"; $T an/s1-pull-release/frames --pred dark --thresh 90 --region 0,60,402,175 --pick largest --prop h
echo "=== s1-scroll-drag: title dark bbox"; $T an/s1-scroll-drag/frames --pred dark --thresh 90 --region 0,60,402,175 --pick largest --prop h --quiet
echo "=== s4-menu-open-recv: backdrop dim (x=380..400,y=380..420)"; $L an/s4-menu-open-recv/frames 380,380,400,420
echo "=== s4-menu-open-recv: pressed bubble ('Where should we go?') gray bbox"; $T an/s4-menu-open-recv/frames --pred color:233,233,235 --thresh 10 --region 0,300,260,380 --pick largest --prop w
echo "=== s4-menu-dismiss: backdrop"; $L an/s4-menu-dismiss/frames 380,380,400,420
echo "=== s1-row-menu-open: backdrop"; $L an/s1-row-menu-open/frames 370,820,400,860
echo "=== s6-statusbar-tap: top bubble y0"; $T an/s6-statusbar-tap/frames --pred green --thresh 30 --region 0,0,402,874 --pick highest --prop y0 --bezier
echo "=== s6-scroll-up"; $T an/s6-scroll-up/frames --pred green --thresh 30 --region 0,0,402,874 --pick highest --prop y0 --quiet
} > an/results.txt 2>&1
echo done
