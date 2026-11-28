#!/usr/bin/env bash
set -u

INTERVAL="${CMUX_BOUNDS_TUI_INTERVAL:-1}"
USE_ALT_SCREEN="${CMUX_BOUNDS_TUI_ALT_SCREEN:-1}"
HAVE_ALT_SCREEN=0
NEEDS_DRAW=1

cleanup() {
  printf '\033[0m\033[?7h\033[?25h'
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
trap 'NEEDS_DRAW=1' WINCH
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

blank_line() {
  repeat_char " " "$1"
}

replace_at() {
  local line="$1"
  local col="$2"
  local text="$3"
  local width="${#line}"
  local max_len prefix suffix

  if (( col < 1 || col > width || width == 0 )); then
    printf '%s' "$line"
    return 0
  fi

  max_len=$(( width - col + 1 ))
  if (( ${#text} > max_len )); then
    text="${text:0:max_len}"
  fi

  prefix="${line:0:$(( col - 1 ))}"
  suffix="${line:$(( col - 1 + ${#text} ))}"
  printf '%s%s%s' "$prefix" "$text" "$suffix"
}

center_col() {
  local width="$1"
  local text="$2"
  if (( ${#text} >= width )); then
    printf '1'
  else
    printf '%s' "$(( (width - ${#text}) / 2 + 1 ))"
  fi
}

put_line_text() {
  local row="$1"
  local col="$2"
  local text="$3"
  if (( row < 1 || row > ROWS )); then
    return 0
  fi
  LINES_BUFFER[$row]="$(replace_at "${LINES_BUFFER[$row]}" "$col" "$text")"
}

put_centered_line_text() {
  local row="$1"
  local text="$2"
  put_line_text "$row" "$(center_col "$COLS" "$text")" "$text"
}

draw_frame() {
  local row col label mid_row right_label bottom_label text now

  for (( row = 1; row <= ROWS; row++ )); do
    LINES_BUFFER[$row]="$(blank_line "$COLS")"
  done

  if (( COLS == 1 )); then
    LINES_BUFFER[1]="1"
    return 0
  fi

  LINES_BUFFER[1]="1$(repeat_char "-" "$(( COLS - 2 ))")2"
  LINES_BUFFER[$ROWS]="3$(repeat_char "-" "$(( COLS - 2 ))")4"

  for (( row = 2; row <= ROWS - 1; row++ )); do
    put_line_text "$row" 1 "|"
    put_line_text "$row" "$COLS" "|"
  done

  for (( col = 10; col < COLS; col += 10 )); do
    put_line_text 2 "$col" "$(( (col / 10) % 10 ))"
    if (( ROWS > 4 )); then
      put_line_text "$(( ROWS - 1 ))" "$col" "$(( (col / 10) % 10 ))"
    fi
  done

  for (( row = 5; row < ROWS; row += 5 )); do
    label="r$row"
    put_line_text "$row" 3 "$label"
    put_line_text "$row" "$(( COLS - ${#label} - 1 ))" "$label"
  done

  now="$(date '+%H:%M:%S')"
  put_centered_line_text 3 "CMUX BOUNDS CHECK"
  put_centered_line_text 4 "rows=$ROWS cols=$COLS redraw=$now"

  if (( ROWS >= 10 )); then
    put_centered_line_text 6 "Single ASCII rectangle, no fill or inverse video."
    put_centered_line_text 7 "Corners 1 2 3 4 and all four edges must be visible."
  fi

  if (( ROWS >= 14 )); then
    mid_row=$(( ROWS / 2 ))
    put_line_text "$mid_row" 3 "left col=1"
    right_label="right col=$COLS"
    put_line_text "$mid_row" "$(( COLS - ${#right_label} - 1 ))" "$right_label"
  fi

  bottom_label="bottom row=$ROWS"
  put_line_text "$(( ROWS - 1 ))" 3 "$bottom_label"
  text="q quits"
  put_line_text "$(( ROWS - 1 ))" "$(( COLS - ${#text} - 1 ))" "$text"
}

draw() {
  read -r ROWS COLS < <(read_size)

  printf '\033[0m\033[?7l\033[H'

  if (( ROWS < 6 || COLS < 24 )); then
    printf 'CMUX BOUNDS CHECK\r\n'
    printf 'Too small: %sx%s\r\n' "$ROWS" "$COLS"
    printf 'Need 6x24 or larger.'
    return 0
  fi

  LINES_BUFFER=()
  draw_frame

  local row
  for (( row = 1; row <= ROWS; row++ )); do
    if (( row > 1 )); then
      printf '\r\n'
    fi
    printf '%s' "${LINES_BUFFER[$row]}"
  done
}

if [[ "$USE_ALT_SCREEN" != "0" ]]; then
  printf '\033[?1049h'
  HAVE_ALT_SCREEN=1
fi
printf '\033[?7l\033[?25l\033[H\033[2J'

while true; do
  if (( NEEDS_DRAW == 1 )); then
    draw
    NEEDS_DRAW=0
  fi
  if [[ -t 0 ]]; then
    if IFS= read -r -s -n 1 -t "$INTERVAL" key; then
      case "$key" in
        q|Q) exit_clean ;;
      esac
    else
      NEEDS_DRAW=1
    fi
  else
    sleep "$INTERVAL"
    NEEDS_DRAW=1
  fi
done
