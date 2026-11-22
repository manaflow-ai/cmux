#!/bin/bash
# Reproduces the reference images. Expects the tagged app unzipped at /tmp/specvis/app, scratch configs in /tmp/specvis/cfg,
# rpc.sh wrapping the bundled cmux CLI with CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock, and /tmp/specvis/wid holding the
# CGWindowID (winlist.swift). Coordinates are top-left window points for the default compact scene described in pixel-parity.md.
# usage: capture.sh <mode: dark|light>
source /tmp/specvis/lib.sh
M=$1
appearance $M; cfg '{}'; tunreset focus.inactiveTabStyle; tunreset sidebar.sections.look; away
shot window/$M-default
shot sidebar/$M-default 0 0 190 165
hover 95 124; shot sidebar/$M-row-hover 0 0 190 165
hover 95 71; shot sidebar/$M-selected-row-hover 0 0 190 165
hover 95 97; shot sidebar/$M-unread-badge-hover 0 0 190 165
hover 60 38; shot sidebar/$M-home-item-hover 0 0 190 60
hover 60 620; shot sidebar/$M-footer-hover 0 600 190 120
away
shot tabs/$M-strips 190 0 910 30
hover 265 15; shot tabs/$M-inactive-tab-hover 190 0 420 30
hover 371 15; shot tabs/$M-close-button-hover 190 0 420 30
hover 680 15; shot tabs/$M-selected-tab-hover 595 0 340 30
hover 868 14; shot tabs/$M-new-tab-hover 595 0 340 30
hover 563 15; shot tabs/$M-trailing-button-hover 480 0 120 30
away
for s in fade tonal quiet; do tun focus.inactiveTabStyle "\"$s\""; shot tabs/$M-inactive-pane-$s 190 0 910 30; done; tunreset focus.inactiveTabStyle
for c in subtle standard strong; do cfg "{\"focusRing\":{\"contrast\":\"$c\"}}"; shot panes/$M-focus-ring-$c 560 0 120 120; done
for f in both border tabs none; do cfg "{\"appearance\":{\"focusIndicator\":\"$f\"}}"; shot panes/$M-focus-indicator-$f 190 0 910 200; done
cfg '{"appearance":{"tabBarBackground":"darker"}}'; shot tabs/$M-tabbar-darker 190 0 910 60; shot window/$M-tabbar-darker
cfg '{"appearance":{"borders":"none"}}'; shot window/$M-borders-none
cfg '{"appearance":{"density":"comfortable"}}'; shot window/$M-density-comfortable
cfg '{}'
for l in quiet card tray lines linesIcons; do tun sidebar.sections.look "\"$l\""; shot sidebar/$M-look-$l 0 0 190 720; done; tunreset sidebar.sections.look
away
