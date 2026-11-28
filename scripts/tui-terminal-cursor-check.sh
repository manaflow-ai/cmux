#!/usr/bin/env bash
set -u

INTERVAL="${CMUX_CURSOR_TUI_INTERVAL:-1}"
USE_ALT_SCREEN="${CMUX_CURSOR_TUI_ALT_SCREEN:-1}"
HAVE_ALT_SCREEN=0
NEEDS_DRAW=1

cleanup() {
  printf '\033[0m\033[?7h\033[?25h\033[0 q'
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

clamp() {
  local value="$1"
  local min_value="$2"
  local max_value="$3"
  if (( value < min_value )); then
    printf '%s' "$min_value"
  elif (( value > max_value )); then
    printf '%s' "$max_value"
  else
    printf '%s' "$value"
  fi
}

draw_frame() {
  local row col line_start line_end label now

  for (( row = 1; row <= ROWS; row++ )); do
    LINES_BUFFER[$row]="$(blank_line "$COLS")"
  done

  if (( COLS == 1 )); then
    LINES_BUFFER[1]="@"
    TARGET_ROW=1
    TARGET_COL=1
    return 0
  fi

  LINES_BUFFER[1]="1$(repeat_char "-" "$(( COLS - 2 ))")2"
  LINES_BUFFER[$ROWS]="3$(repeat_char "-" "$(( COLS - 2 ))")4"

  for (( row = 2; row <= ROWS - 1; row++ )); do
    put_line_text "$row" 1 "|"
    put_line_text "$row" "$COLS" "|"
  done

  TARGET_ROW="$(clamp "$(( ROWS / 2 ))" 6 "$(( ROWS - 2 ))")"
  TARGET_COL="$(clamp "$(( COLS / 2 ))" 12 "$(( COLS - 2 ))")"

  line_start="$(clamp "$(( TARGET_COL - 10 ))" 2 "$(( COLS - 1 ))")"
  line_end="$(clamp "$(( TARGET_COL + 10 ))" 2 "$(( COLS - 1 ))")"
  for (( col = line_start; col <= line_end; col++ )); do
    put_line_text "$TARGET_ROW" "$col" "-"
  done
  for (( row = TARGET_ROW - 4; row <= TARGET_ROW + 4; row++ )); do
    if (( row > 1 && row < ROWS )); then
      put_line_text "$row" "$TARGET_COL" "|"
    fi
  done

  put_line_text "$TARGET_ROW" "$TARGET_COL" "@"

  now="$(date '+%H:%M:%S')"
  put_centered_line_text 3 "CMUX CURSOR CHECK"
  put_centered_line_text 4 "rows=$ROWS cols=$COLS cursor_row=$TARGET_ROW cursor_col=$TARGET_COL"
  put_centered_line_text 5 "The active cursor must sit on @ in macOS, iOS, and iPadOS."

  label="target row $TARGET_ROW"
  put_line_text "$TARGET_ROW" 3 "$label"

  label="target col $TARGET_COL"
  put_line_text "$(( TARGET_ROW + 2 ))" "$(( TARGET_COL + 2 ))" "$label"

  label="redraw $now"
  put_line_text "$(( ROWS - 1 ))" 3 "$label"
  put_line_text "$(( ROWS - 1 ))" "$(( COLS - 7 ))" "q quits"
}

draw() {
  read -r ROWS COLS < <(read_size)

  printf '\033[0m\033[?7l\033[?12l\033[2 q\033[?25h\033[H'

  if (( ROWS < 8 || COLS < 28 )); then
    printf 'CMUX CURSOR CHECK\r\n'
    printf 'Too small: %sx%s\r\n' "$ROWS" "$COLS"
    printf 'Need 8x28 or larger.'
    printf '\033[?12l\033[2 q\033[?25h\033[1;1H'
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

  printf '\033[?12l\033[2 q\033[?25h\033[%s;%sH' "$TARGET_ROW" "$TARGET_COL"
}

if [[ "$USE_ALT_SCREEN" != "0" ]]; then
  printf '\033[?1049h'
  HAVE_ALT_SCREEN=1
fi
printf '\033[?7l\033[?12l\033[2 q\033[?25h\033[H\033[2J'

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
    fi
  else
    sleep "$INTERVAL"
  fi
done
