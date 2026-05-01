#!/usr/bin/env bash
set -u

INTERVAL="${CMUX_BOUNDS_TUI_INTERVAL:-1}"
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

  if ! is_positive_int "$rows" || ! is_positive_int "$cols" || [[ "$rows" == "$cols" ]]; then
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

draw() {
  local rows cols horizontal top bottom row col label last_label center_col now edge_warning corner_help rail_help resize_help bottom_help ruler_help
  read -r rows cols < <(read_size)

  printf '\033[0m\033[H\033[2J'

  if (( rows < 8 || cols < 30 )); then
    put_text "$rows" "$cols" 1 1 "CMUX BOUNDS CHECK"
    put_text "$rows" "$cols" 2 1 "Terminal too small: rows=$rows cols=$cols"
    put_text "$rows" "$cols" 3 1 "Need at least 8 rows x 30 cols."
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
    bottom_help="bottom row=$(( rows - 2 )); next is border"
    ruler_help="ruler visible to both rails"
  else
    corner_help="All four corners must be visible: 1 top-left, 2 top-right, 3 bottom-left, 4 bottom-right"
    rail_help="Right border missing means width clipping. Bottom border hidden means height overlap."
    edge_warning="CUT OFF OR COVERED if you cannot see this full border"
    resize_help="Resize fast or rotate: this display should update without losing a corner."
    bottom_help="bottom inner row=$(( rows - 2 )); the next line is the bottom border"
    ruler_help="column ruler marks every 10 cells; this line should be fully visible"
  fi

  put_inner_center "$rows" "$cols" 3 "CMUX TERMINAL BOUNDS VISUAL CHECK"
  put_inner_center "$rows" "$cols" 4 "reported size: rows=$rows cols=$cols  redraw=$now"
  put_inner_center "$rows" "$cols" 6 "$corner_help"
  put_inner_center "$rows" "$cols" 7 "$rail_help"
  put_inner_center "$rows" "$cols" 9 "$edge_warning"

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

  put_inner_text "$rows" "$cols" "$(( rows - 2 ))" "$bottom_help"
  put_inner_center "$rows" "$cols" "$(( rows - 1 ))" "$ruler_help"
}

if [[ "$USE_ALT_SCREEN" != "0" ]]; then
  printf '\033[?1049h'
  HAVE_ALT_SCREEN=1
fi
printf '\033[?25l'

while true; do
  draw
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
