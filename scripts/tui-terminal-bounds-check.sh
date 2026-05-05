#!/usr/bin/env bash
set -u

INTERVAL="${CMUX_BOUNDS_TUI_INTERVAL:-1}"
REDRAW_EVERY="${CMUX_BOUNDS_TUI_REDRAW_EVERY:-0}"
USE_ALT_SCREEN="${CMUX_BOUNDS_TUI_ALT_SCREEN:-1}"
HAVE_ALT_SCREEN=0

cleanup() {
  printf '\033[0m\033[?25h'
  if (( HAVE_ALT_SCREEN == 1 )); then
    printf '\033[?1049l'
  fi
}

exit_clean() {
  cleanup
  exit 0
}

exit_interrupted() {
  cleanup
  exit 130
}

trap exit_interrupted INT TERM
trap cleanup EXIT

repeat_char() {
  local ch="$1"
  local count="$2"
  local out=""
  if (( count <= 0 )); then
    return 0
  fi
  printf -v out '%*s' "$count" ''
  printf '%s' "${out// /$ch}"
}

is_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" > 0 ))
}

read_size() {
  local size rows cols
  size="$(stty size 2>/dev/null || true)"
  rows="${size%% *}"
  cols="${size##* }"

  if ! is_positive_int "$rows" || ! is_positive_int "$cols"; then
    rows="${LINES:-0}"
    cols="${COLUMNS:-0}"
  fi

  if ! is_positive_int "$rows"; then
    rows="$(tput lines 2>/dev/null || printf '24')"
  fi
  if ! is_positive_int "$cols"; then
    cols="$(tput cols 2>/dev/null || printf '80')"
  fi
  if ! is_positive_int "$rows"; then
    rows=24
  fi
  if ! is_positive_int "$cols"; then
    cols=80
  fi

  printf '%s %s' "$rows" "$cols"
}

move_to() {
  printf '\033[%d;%dH' "$1" "$2"
}

put_text() {
  local rows="$1"
  local cols="$2"
  local row="$3"
  local col="$4"
  local text="$5"
  local max_len

  if (( row < 1 || row > rows || col < 1 || col > cols )); then
    return 0
  fi

  max_len=$(( cols - col + 1 ))
  if (( ${#text} > max_len )); then
    text="${text:0:max_len}"
  fi

  move_to "$row" "$col"
  printf '%s' "$text"
}

put_center() {
  local rows="$1"
  local cols="$2"
  local row="$3"
  local text="$4"
  local col

  if (( ${#text} >= cols )); then
    put_text "$rows" "$cols" "$row" 1 "$text"
    return 0
  fi

  col=$(( (cols - ${#text}) / 2 + 1 ))
  put_text "$rows" "$cols" "$row" "$col" "$text"
}

put_inner_text() {
  local rows="$1"
  local cols="$2"
  local row="$3"
  local text="$4"
  local max_len

  if (( cols <= 2 )); then
    return 0
  fi

  max_len=$(( cols - 2 ))
  if (( ${#text} > max_len )); then
    text="${text:0:max_len}"
  fi

  put_text "$rows" "$cols" "$row" 2 "$text"
}

put_inner_center() {
  local rows="$1"
  local cols="$2"
  local row="$3"
  local text="$4"
  local inner_width col

  if (( cols <= 2 )); then
    return 0
  fi

  inner_width=$(( cols - 2 ))
  if (( ${#text} > inner_width )); then
    text="${text:0:inner_width}"
  fi

  col=$(( (inner_width - ${#text}) / 2 + 2 ))
  put_text "$rows" "$cols" "$row" "$col" "$text"
}

put_ansi_text() {
  local rows="$1"
  local cols="$2"
  local row="$3"
  local col="$4"
  local visible_len="$5"
  local text="$6"
  local max_len

  if (( row < 1 || row > rows || col < 1 || col > cols )); then
    return 0
  fi

  max_len=$(( cols - col + 1 ))
  if (( visible_len > max_len )); then
    return 0
  fi

  move_to "$row" "$col"
  printf '%b\033[0m' "$text"
}

put_ansi_center() {
  local rows="$1"
  local cols="$2"
  local row="$3"
  local visible_len="$4"
  local text="$5"
  local inner_width col

  if (( cols <= 2 )); then
    return 0
  fi

  inner_width=$(( cols - 2 ))
  if (( visible_len > inner_width )); then
    return 0
  fi

  col=$(( (inner_width - visible_len) / 2 + 2 ))
  put_ansi_text "$rows" "$cols" "$row" "$col" "$visible_len" "$text"
}

draw_ansi_color_check() {
  local rows="$1"
  local cols="$2"
  local row="$3"
  local esc=$'\033'
  local compact fg bg codes index code label_len

  if (( row < 1 || row > rows - 2 || cols < 22 )); then
    return 0
  fi

  if (( cols < 45 || row + 2 > rows - 3 )); then
    compact="ANSI: ${esc}[31mR${esc}[0m ${esc}[32mG${esc}[0m ${esc}[33mY${esc}[0m ${esc}[34mB${esc}[0m ${esc}[35mM${esc}[0m ${esc}[36mC${esc}[0m ${esc}[37mW${esc}[0m"
    put_ansi_center "$rows" "$cols" "$row" 19 "$compact"
    return 0
  fi

  put_inner_center "$rows" "$cols" "$row" "ANSI theme colors"

  bg="BG: "
  codes=(40 41 42 43 44 45 46 47)
  for index in "${!codes[@]}"; do
    code="${codes[$index]}"
    bg+="${esc}[${code}m  ${esc}[0m"
    if (( index < ${#codes[@]} - 1 )); then
      bg+=" "
    fi
  done
  put_ansi_center "$rows" "$cols" "$(( row + 1 ))" 27 "$bg"

  if (( row + 2 <= rows - 2 )); then
    fg="FG: ${esc}[30mK${esc}[0m ${esc}[31mR${esc}[0m ${esc}[32mG${esc}[0m ${esc}[33mY${esc}[0m ${esc}[34mB${esc}[0m ${esc}[35mM${esc}[0m ${esc}[36mC${esc}[0m ${esc}[37mW${esc}[0m"
    label_len=19
    put_ansi_center "$rows" "$cols" "$(( row + 2 ))" "$label_len" "$fg"
  fi
}

draw() {
  local rows cols inner_rows inner_cols horizontal top bottom row col label last_label center_col now edge_warning corner_help rail_help resize_help bottom_help ruler_help visible_help inner_help corner_detail color_row
  read -r rows cols < <(read_size)
  inner_rows=$(( rows - 2 ))
  inner_cols=$(( cols - 2 ))

  printf '\033[0m\033[H\033[2J'

  if (( rows < 6 || cols < 12 )); then
    put_text "$rows" "$cols" 1 1 "CMUX BOUNDS CHECK"
    put_text "$rows" "$cols" 2 1 "Terminal too small: rows=$rows cols=$cols"
    put_text "$rows" "$cols" 3 1 "Need at least 6 rows x 12 cols."
    put_text "$rows" "$cols" 4 1 "Resize, rotate, or hide UI chrome."
    return 0
  fi

  horizontal="$(repeat_char '=' "$(( cols - 2 ))")"
  top="1${horizontal}2"
  bottom="3${horizontal}4"

  printf '\033[7m'
  put_text "$rows" "$cols" 1 1 "$top"
  put_text "$rows" "$cols" "$rows" 1 "$bottom"
  for (( row = 2; row <= rows - 1; row++ )); do
    put_text "$rows" "$cols" "$row" 1 "|"
    put_text "$rows" "$cols" "$row" "$cols" "|"
  done
  printf '\033[0m'

  center_col=$(( cols / 2 ))
  for (( col = 10; col < cols; col += 10 )); do
    put_text "$rows" "$cols" 2 "$col" "$(( (col / 10) % 10 ))"
    put_text "$rows" "$cols" "$(( rows - 1 ))" "$col" "$(( (col / 10) % 10 ))"
    if (( rows > 14 )); then
      put_text "$rows" "$cols" "$(( rows / 2 ))" "$col" "+"
    fi
  done

  for (( row = 5; row < rows; row += 5 )); do
    label="r$row"
    put_text "$rows" "$cols" "$row" 3 "$label"
    put_text "$rows" "$cols" "$row" "$(( cols - ${#label} - 1 ))" "$label"
  done

  now="$(date '+%H:%M:%S')"
  if (( cols < 70 )); then
    corner_help="Corners visible: 1 2 3 4"
    rail_help="No missing rails, no covered bottom"
    edge_warning="CUT/OFF/COVERED means bounds are wrong"
    resize_help="Resize/rotate: corners stay visible"
    bottom_help="bottom row=$inner_rows; next is border"
    ruler_help="ruler visible to both rails"
    visible_help="grid=${cols}x${rows} cells"
    inner_help="inner=${inner_cols}x${inner_rows} cells"
    corner_detail="tl=1 tr=2 bl=3 br=4"
  else
    corner_help="All four corners must be visible: 1 top-left, 2 top-right, 3 bottom-left, 4 bottom-right"
    rail_help="Right border missing means width clipping. Bottom border hidden means height overlap."
    edge_warning="CUT OFF OR COVERED if you cannot see this full border"
    resize_help="Resize fast or rotate: this display should update without losing a corner."
    bottom_help="bottom inner row=$inner_rows; the next line is the bottom border"
    ruler_help="column ruler marks every 10 cells; this line should be fully visible"
    visible_help="visible terminal grid=${cols} cols x ${rows} rows (${cols}x${rows} cells)"
    inner_help="inside border=${inner_cols} cols x ${inner_rows} rows (${inner_cols}x${inner_rows} cells)"
    corner_detail="corner labels: 1=top-left 2=top-right 3=bottom-left 4=bottom-right"
  fi

  if (( cols < 45 )); then
    put_inner_center "$rows" "$cols" 3 "CMUX BOUNDS CHECK"
    put_inner_center "$rows" "$cols" 4 "rows=$rows cols=$cols"
  else
    put_inner_center "$rows" "$cols" 3 "CMUX TERMINAL BOUNDS VISUAL CHECK"
    put_inner_center "$rows" "$cols" 4 "reported size: rows=$rows cols=$cols  cells=${cols}x${rows}  redraw=$now"
  fi
  put_inner_center "$rows" "$cols" 6 "$corner_help"
  put_inner_center "$rows" "$cols" 7 "$rail_help"
  put_inner_center "$rows" "$cols" 9 "$edge_warning"
  if (( rows >= 12 )); then
    put_inner_center "$rows" "$cols" 10 "$visible_help"
  fi
  if (( rows >= 13 )); then
    put_inner_center "$rows" "$cols" 11 "$inner_help"
  fi
  if (( rows >= 14 )); then
    put_inner_center "$rows" "$cols" 12 "$corner_detail"
  fi

  if (( rows >= 18 )); then
    if (( cols < 70 )); then
      put_inner_center "$rows" "$cols" "$(( rows / 2 - 2 ))" "RAILS TOUCH TRUE EDGES"
      put_text "$rows" "$cols" "$(( rows / 2 ))" 3 "left col=1"
      last_label="right col=$cols"
    else
      put_inner_center "$rows" "$cols" "$(( rows / 2 - 2 ))" "LEFT AND RIGHT RAILS SHOULD TOUCH THE TRUE EDGES"
      put_text "$rows" "$cols" "$(( rows / 2 ))" 3 "left edge col=1"
      last_label="right edge col=$cols"
    fi
    put_text "$rows" "$cols" "$(( rows / 2 ))" "$(( cols - ${#last_label} - 1 ))" "$last_label"
    put_inner_center "$rows" "$cols" "$(( rows / 2 + 2 ))" "$resize_help"
  fi

  if (( rows >= 16 )); then
    color_row=$(( rows / 2 + 4 ))
    if (( color_row > rows - 5 )); then
      color_row=$(( rows - 5 ))
    fi
    if (( color_row < 13 )); then
      color_row=13
    fi
    draw_ansi_color_check "$rows" "$cols" "$color_row"
  fi

  put_inner_text "$rows" "$cols" "$(( rows - 2 ))" "$bottom_help"
  put_inner_center "$rows" "$cols" "$(( rows - 1 ))" "$ruler_help"
}

if [[ "$USE_ALT_SCREEN" != "0" ]]; then
  printf '\033[?1049h'
  HAVE_ALT_SCREEN=1
fi
printf '\033[?25l'

LAST_DRAWN_SIZE=""
LAST_DRAWN_AT=0
while true; do
  current_size="$(read_size)"
  now_epoch="$(date +%s)"
  if [[ "$current_size" != "$LAST_DRAWN_SIZE" ]] ||
     { is_positive_int "$REDRAW_EVERY" && (( now_epoch - LAST_DRAWN_AT >= REDRAW_EVERY )); }; then
    draw
    LAST_DRAWN_SIZE="$current_size"
    LAST_DRAWN_AT="$now_epoch"
  fi
  if [[ -t 0 ]]; then
    if IFS= read -r -s -n 1 -t "$INTERVAL" key; then
      case "$key" in
        q|Q) exit_clean ;;
      esac
    fi
  else
    sleep "$INTERVAL"
  fi
done
