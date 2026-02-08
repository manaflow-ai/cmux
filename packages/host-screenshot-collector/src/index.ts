import { query } from "@anthropic-ai/claude-agent-sdk";
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import * as path from "node:path";
import { z } from "zod";

import { logToScreenshotCollector } from "./logger";
import { formatClaudeMessage } from "./claudeMessageFormatter";

export const SCREENSHOT_STORAGE_ROOT = "/root/screenshots";

// Post-processing Python script content (embedded from scripts/post_process_video.py)
// This script handles: cursor overlay, video trimming, speed adjustment, and GIF generation
const POST_PROCESS_VIDEO_SCRIPT = `#!/usr/bin/env python3
"""
Post-process screen recording video.

This script processes raw.mp4 into a final workflow video with:
1. Cursor overlay animation based on click events
2. Trimming of inactive sections
3. Speed-up of transitions
4. GIF preview generation for GitHub comments

Usage:
    python3 post_process_video.py <output_dir>

Input files (in output_dir):
    - raw.mp4: The raw screen recording
    - events.log: JSON-lines file with click events
    - video-metadata.json: Optional metadata with fileName and description

Output files (in output_dir):
    - workflow.mp4: Processed video (or custom name from metadata)
    - workflow.gif: Animated GIF preview for GitHub (or custom name)
"""

import subprocess
import os
import sys
import json

# Convex storage has 20MB limit for files
CONVEX_SIZE_LIMIT_MB = 20

# Pre-rendered cursor PNG as base64 (32x32 macOS-style pointer)
CURSOR_B64 = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAABX0lEQVR4nO2U4XGCQBCF31ag6eBSQehA7CAdZKlASzg6oANJCalA6EArQCsIHZB3msQxAsJBxj98Mzs7DOy8j72ZEzyYSWASmAQmgUlgEhgkUFVVCOAgIgd4MlTgk82xFJEde2+GClRRFGGz2ZR8XIqHxGABhkJVvSVGEXCop8R52hPm/wo41EPiMu0B868EHNpT4nq6J8y/EXBoD4nb6R4wv1bAoR0l6qc7wvxGAYdeJJ5FxPUbmqc7wPxWAcd2u0UYhksRyVBD+/QdmF8rUBQFjDH4Zs8K+d3/boCrRpqmyPMcq9UKSZK8i4jiDudpT5hfrtfrmTvrIAj2FHiJeDXP5/PTFtifKFH75z8MFQjYLIAdK2EdjDGz4/F42oiqxiJi0cIggb9QKLXWvsVxjMVigSzLchEJ0cLYAqYsy4J/7o4E1toPCrzyVSOjCjgooeAVAKBkKQVcb2R0gb58AQH2qSGP9lZkAAAAAElFTkSuQmCC"


def log(msg):
    """Print to stderr for logging."""
    print(msg, file=sys.stderr)


def parse_events_log(events_log_path):
    """Parse events.log for click events and recording start time."""
    clicks = []  # list of (timestamp_ms, x, y)
    recording_start_ms = None

    log(f"Reading events from {events_log_path}")

    line_count = 0
    try:
        with open(events_log_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                line_count += 1
                event = json.loads(line)
                ts = event.get("timestamp", 0)
                event_type = event.get("event", "")

                # Detect recording start
                if event_type == "recording_start":
                    if recording_start_ms is None:
                        recording_start_ms = ts
                        log(f"Found recording start at {ts}")

                # Click event - has screen coordinates directly
                elif event_type == "click":
                    x = event.get("x", 0)
                    y = event.get("y", 0)
                    clicks.append((ts, x, y))
                    log(f"click at ({x}, {y}) ts={ts}")

        log(f"Processed {line_count} events")
    except FileNotFoundError:
        log(f"ERROR: events.log not found: {events_log_path}")
    except Exception as e:
        log(f"ERROR reading events.log: {e}")

    log(f"Found {len(clicks)} clicks")
    return clicks, recording_start_ms


def validate_raw_video(raw_path, outdir):
    """Validate raw.mp4 and attempt recovery if needed. Returns True if valid."""
    if not os.path.exists(raw_path):
        log(f"ERROR: raw.mp4 not found at {raw_path}")
        return False

    raw_size = os.path.getsize(raw_path)
    log(f"raw.mp4 size: {raw_size} bytes")
    if raw_size < 1000:
        log(f"ERROR: raw.mp4 is too small ({raw_size} bytes) - likely corrupted")
        return False

    # Validate raw.mp4 with ffprobe
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=codec_name,width,height,duration",
         "-of", "csv=p=0", raw_path],
        capture_output=True, text=True
    )

    if probe.returncode != 0:
        log("ERROR: raw.mp4 failed ffprobe validation")
        log(f"ffprobe stderr: {probe.stderr}")

        # Check if it's a moov atom issue (common with fragmented MP4)
        is_moov_issue = "moov" in probe.stderr.lower() or "Invalid data" in probe.stderr

        if is_moov_issue:
            log("Detected moov atom issue - attempting recovery with re-encoding...")
            salvage = subprocess.run([
                "ffmpeg", "-y", "-fflags", "+genpts+igndts",
                "-i", raw_path,
                "-c:v", "libx264", "-preset", "ultrafast", "-crf", "26",
                "-movflags", "+faststart",
                f"{outdir}/workflow.mp4"
            ], capture_output=True, text=True)
        else:
            log("Attempting to salvage with ffmpeg copy...")
            salvage = subprocess.run(
                f'ffmpeg -y -i "{raw_path}" -c copy -movflags +faststart "{outdir}/workflow.mp4"',
                shell=True, capture_output=True, text=True
            )

        if salvage.returncode == 0:
            verify = subprocess.run(
                ["ffprobe", "-v", "error", f"{outdir}/workflow.mp4"],
                capture_output=True, text=True
            )
            if verify.returncode == 0:
                log("Salvage successful and verified")
                os.remove(raw_path)
                return False  # Already created workflow.mp4
            else:
                log(f"Salvaged file failed verification: {verify.stderr}")
                os.rename(raw_path, f"{outdir}/workflow.mp4")
        else:
            log(f"Salvage failed: {salvage.stderr}")
            os.rename(raw_path, f"{outdir}/workflow.mp4")
        return False  # Already handled

    log(f"raw.mp4 stream info: {probe.stdout.strip()}")
    return True


def create_cursor_png(cursor_path):
    """Create cursor PNG file from embedded base64 data."""
    import base64
    try:
        cursor_data = base64.b64decode(CURSOR_B64)
        with open(cursor_path, 'wb') as f:
            f.write(cursor_data)
        log(f"Created cursor PNG at {cursor_path}")
        return True
    except Exception as e:
        log(f"Failed to create cursor PNG: {e}")
        return False


def add_cursor_overlay_png(outdir, clicks):
    """Add cursor overlay using PNG image. Returns True on success."""
    cursor_path = f"{outdir}/cursor.png"
    if not create_cursor_png(cursor_path):
        return False

    # Screen center and cursor tip offset
    cx, cy = 960, 540
    tip_offset = 4  # cursor tip offset within 32x32 image

    first_t, first_x, first_y = clicks[0]
    anim_dur = max(first_t, 0.1)

    log(f"Animation: center ({cx},{cy}) -> ({first_x},{first_y}) over {anim_dur:.2f}s")

    # Animation expressions for smooth movement
    anim_x_expr = f"({cx}-{tip_offset}+({first_x}-{cx})*min(t/{anim_dur},1))"
    anim_y_expr = f"({cy}-{tip_offset}+({first_y}-{cy})*min(t/{anim_dur},1))"

    # Build overlay filters
    overlay_parts = []
    overlay_parts.append(f"overlay=x='{anim_x_expr}':y='{anim_y_expr}':enable='between(t,0,{anim_dur:.2f})'")

    for i, (t, x, y) in enumerate(clicks):
        end_t = clicks[i+1][0] if i+1 < len(clicks) else 9999
        if end_t <= t:
            continue
        overlay_parts.append(f"overlay=x={x-tip_offset}:y={y-tip_offset}:enable='between(t,{t:.2f},{end_t:.2f})'")

    # Build filter chain
    filter_chain = f"[0:v][1:v]{overlay_parts[0]}[v0]"
    for i, overlay in enumerate(overlay_parts[1:], 1):
        filter_chain += f";[v{i-1}][1:v]{overlay}[v{i}]"
    last_idx = len(overlay_parts) - 1

    log(f"Drawing cursor overlay with {len(overlay_parts)} overlay filters")
    result = subprocess.run([
        "ffmpeg", "-y",
        "-i", f"{outdir}/raw.mp4",
        "-i", cursor_path,
        "-filter_complex", filter_chain,
        "-map", f"[v{last_idx}]",
        "-movflags", "+faststart",
        f"{outdir}/with_cursor.mp4"
    ], capture_output=True, text=True)

    if result.returncode != 0:
        log(f"Cursor overlay failed: {result.stderr}")
        return False

    return True


def add_cursor_overlay_drawtext(outdir, clicks):
    """Fallback: Add cursor using drawtext. Returns True on success."""
    cursor_char = "⮝"
    shadow_offset = 2
    cursor_size = 28
    cx, cy = 960, 540
    tip_offset_x, tip_offset_y = -4, -2

    first_t, first_x, first_y = clicks[0]
    anim_dur = max(first_t, 0.1)

    # Animation expressions
    anim_x = f"({cx}+{tip_offset_x}+({first_x}-{cx})*min(t/{anim_dur},1))"
    anim_y = f"({cy}+{tip_offset_y}+({first_y}-{cy})*min(t/{anim_dur},1))"
    shadow_x = f"({cx}+{tip_offset_x}+{shadow_offset}+({first_x}-{cx})*min(t/{anim_dur},1))"
    shadow_y = f"({cy}+{tip_offset_y}+{shadow_offset}+({first_y}-{cy})*min(t/{anim_dur},1))"

    # Build drawtext filter
    drawtext_parts = [
        f"drawtext=text='{cursor_char}':x='{shadow_x}':y='{shadow_y}':fontsize={cursor_size}:fontcolor=black@0.6:enable='between(t,0,{anim_dur:.2f})'",
        f"drawtext=text='{cursor_char}':x='{anim_x}':y='{anim_y}':fontsize={cursor_size}:fontcolor=white:enable='between(t,0,{anim_dur:.2f})'"
    ]

    for i, (t, x, y) in enumerate(clicks):
        end_t = clicks[i+1][0] if i+1 < len(clicks) else 9999
        if end_t <= t:
            continue
        drawtext_parts.append(
            f"drawtext=text='{cursor_char}':x={x+tip_offset_x+shadow_offset}:y={y+tip_offset_y+shadow_offset}:fontsize={cursor_size}:fontcolor=black@0.6:enable='between(t,{t:.2f},{end_t:.2f})'"
        )
        drawtext_parts.append(
            f"drawtext=text='{cursor_char}':x={x+tip_offset_x}:y={y+tip_offset_y}:fontsize={cursor_size}:fontcolor=white:enable='between(t,{t:.2f},{end_t:.2f})'"
        )

    vf = ",".join(drawtext_parts)
    result = subprocess.run(
        f'ffmpeg -y -i "{outdir}/raw.mp4" -vf "{vf}" -movflags +faststart "{outdir}/with_cursor.mp4"',
        shell=True, capture_output=True, text=True
    )

    if result.returncode != 0:
        log(f"Drawtext cursor failed: {result.stderr}")
        return False

    return True


def trim_and_speedup(outdir, clicks, video_duration):
    """Trim inactive sections and speed up transitions."""
    # Trimming parameters
    FAST_SPEED = 10  # Speed for transition segments
    ACTION_BEFORE = 0.3  # seconds before click at normal speed
    ACTION_AFTER = 2.0  # seconds after click at normal speed
    LAST_ACTION_AFTER = 3.0  # extra time for last click
    MAX_TRANSITION = 0.3  # max seconds to keep from gaps before speedup
    END_OF_VIDEO_BUFFER = 1.5  # seconds to keep at end

    # Build segments
    video_segments = []  # (start, end, speed)
    prev_action_end = 0.0
    num_clicks = len(clicks)

    for i, (t, x, y) in enumerate(clicks):
        is_last_click = (i == num_clicks - 1)
        action_start = max(0, t - ACTION_BEFORE)
        after_time = LAST_ACTION_AFTER if is_last_click else ACTION_AFTER
        action_end = min(video_duration, t + after_time)

        # Handle gap before this action
        gap = action_start - prev_action_end
        if gap > 0:
            if gap > MAX_TRANSITION:
                transition_start = action_start - MAX_TRANSITION
                if transition_start > prev_action_end:
                    video_segments.append((transition_start, action_start, FAST_SPEED))
                elif prev_action_end < action_start:
                    video_segments.append((prev_action_end, action_start, FAST_SPEED))
            else:
                video_segments.append((prev_action_end, action_start, FAST_SPEED))

        # Action segment at normal speed
        if video_segments and video_segments[-1][2] == 1 and action_start <= video_segments[-1][1]:
            video_segments[-1] = (video_segments[-1][0], action_end, 1)
        else:
            video_segments.append((action_start, action_end, 1))

        prev_action_end = action_end

    # Handle end of video
    if prev_action_end < video_duration:
        remaining = video_duration - prev_action_end
        if remaining > END_OF_VIDEO_BUFFER:
            video_segments.append((prev_action_end, prev_action_end + END_OF_VIDEO_BUFFER, 1))
            if prev_action_end + END_OF_VIDEO_BUFFER < video_duration:
                video_segments.append((prev_action_end + END_OF_VIDEO_BUFFER, video_duration, FAST_SPEED))
        else:
            video_segments.append((prev_action_end, video_duration, 1))

    log(f"Video segments: {video_segments}")

    # Build complex filter for trimming and speed adjustment
    filter_parts = []
    concat_inputs = []

    for i, (start, end, speed) in enumerate(video_segments):
        if end <= start:
            continue
        pts_factor = 1.0 / speed
        filter_parts.append(f"[0:v]trim=start={start:.3f}:end={end:.3f},setpts={pts_factor}*PTS[v{i}]")
        concat_inputs.append(f"[v{i}]")

    if not concat_inputs:
        log("No segments to process")
        return False

    n_segments = len(concat_inputs)
    filter_complex = ";".join(filter_parts) + f";{''.join(concat_inputs)}concat=n={n_segments}:v=1:a=0[out]"

    result = subprocess.run([
        "ffmpeg", "-y",
        "-i", f"{outdir}/with_cursor.mp4",
        "-filter_complex", filter_complex,
        "-map", "[out]",
        "-movflags", "+faststart",
        f"{outdir}/workflow.mp4"
    ], capture_output=True, text=True)

    if result.returncode != 0:
        log(f"Trim/speedup failed: {result.stderr}")
        return False

    # Cleanup intermediate file
    os.remove(f"{outdir}/with_cursor.mp4")

    total_dur = sum((end - start) / speed for start, end, speed in video_segments)
    log(f"Final video: {n_segments} segments, ~{total_dur:.1f}s (from {video_duration:.1f}s original)")

    return True


def process_no_clicks(outdir):
    """Process video when there are no clicks - just add centered cursor and speed up."""
    log("No clicks found, drawing cursor at center and speeding up 4x")
    cx, cy = 960, 540
    cursor_path = f"{outdir}/cursor.png"

    if create_cursor_png(cursor_path):
        tip_offset = 4
        result = subprocess.run([
            "ffmpeg", "-y",
            "-i", f"{outdir}/raw.mp4",
            "-i", cursor_path,
            "-filter_complex", f"[0:v][1:v]overlay=x={cx-tip_offset}:y={cy-tip_offset},setpts=0.25*PTS[out]",
            "-map", "[out]",
            "-movflags", "+faststart",
            f"{outdir}/workflow.mp4"
        ], capture_output=True, text=True)

        if result.returncode == 0:
            os.remove(f"{outdir}/raw.mp4")
            return True

    # Fallback to just speed up
    result = subprocess.run(
        f'ffmpeg -y -i "{outdir}/raw.mp4" -vf "setpts=0.25*PTS" -movflags +faststart "{outdir}/workflow.mp4"',
        shell=True, capture_output=True, text=True
    )

    if result.returncode == 0:
        os.remove(f"{outdir}/raw.mp4")
        return True

    # Last resort: just copy
    os.rename(f"{outdir}/raw.mp4", f"{outdir}/workflow.mp4")
    return True


def generate_gif_preview(outdir, workflow_path):
    """Generate GIF preview for GitHub comments using two-pass palette."""
    gif_path = f"{outdir}/workflow.gif"
    palette_path = f"{outdir}/palette.png"

    if not os.path.exists(workflow_path):
        log("No workflow video to generate GIF from")
        return False

    gif_success = False

    for fps in [15, 10, 8, 6]:
        log(f"Generating GIF preview (two-pass palette @ {fps}fps)...")

        try:
            # Pass 1: Generate optimized palette
            subprocess.run([
                "ffmpeg", "-y", "-i", workflow_path,
                "-vf", f"fps={fps},palettegen=stats_mode=diff:max_colors=256",
                palette_path
            ], capture_output=True, text=True, timeout=60)

            if not os.path.exists(palette_path):
                continue

            # Pass 2: Generate GIF using palette
            result = subprocess.run([
                "ffmpeg", "-y", "-i", workflow_path, "-i", palette_path,
                "-lavfi", f"fps={fps}[x];[x][1:v]paletteuse=dither=floyd_steinberg:diff_mode=rectangle",
                gif_path
            ], capture_output=True, text=True, timeout=90)

            if result.returncode == 0 and os.path.exists(gif_path):
                gif_size = os.path.getsize(gif_path)
                gif_size_mb = gif_size / 1024 / 1024
                log(f"GIF @ {fps}fps: {gif_size_mb:.2f} MB")

                if gif_size_mb <= CONVEX_SIZE_LIMIT_MB:
                    gif_success = True
                    log(f"GIF fits within {CONVEX_SIZE_LIMIT_MB}MB limit!")
                    break
                else:
                    log(f"GIF too large, trying lower fps...")
                    os.remove(gif_path)

        except subprocess.TimeoutExpired:
            log(f"GIF generation timed out at {fps}fps")

    # Cleanup palette
    if os.path.exists(palette_path):
        os.remove(palette_path)

    if not gif_success and os.path.exists(gif_path):
        os.remove(gif_path)

    return gif_success


def apply_metadata_rename(outdir, workflow_path, gif_path):
    """Rename output files based on video-metadata.json if present."""
    import re

    metadata_path = f"{outdir}/video-metadata.json"
    if not os.path.exists(metadata_path):
        return

    try:
        with open(metadata_path) as f:
            metadata = json.load(f)

        custom_filename = metadata.get("fileName", "").strip()
        if custom_filename:
            # Sanitize filename
            safe_filename = re.sub(r'[^a-zA-Z0-9_-]', '-', custom_filename)
            safe_filename = re.sub(r'-+', '-', safe_filename).strip('-')

            if safe_filename:
                new_mp4_path = f"{outdir}/{safe_filename}.mp4"
                new_gif_path = f"{outdir}/{safe_filename}.gif"

                if os.path.exists(workflow_path) and workflow_path != new_mp4_path:
                    os.rename(workflow_path, new_mp4_path)
                    log(f"Renamed video: {workflow_path} -> {new_mp4_path}")

                if os.path.exists(gif_path) and gif_path != new_gif_path:
                    os.rename(gif_path, new_gif_path)
                    log(f"Renamed GIF: {gif_path} -> {new_gif_path}")

        log(f"Video metadata: {metadata}")

    except Exception as e:
        log(f"Warning: Could not process video metadata: {e}")


def cleanup_temp_files(outdir):
    """Remove temporary files."""
    cursor_path = f"{outdir}/cursor.png"
    if os.path.exists(cursor_path):
        os.remove(cursor_path)
        log("Cleaned up cursor.png")


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 post_process_video.py <output_dir>", file=sys.stderr)
        sys.exit(1)

    outdir = sys.argv[1]
    events_log_path = f"{outdir}/events.log"
    raw_path = f"{outdir}/raw.mp4"
    workflow_path = f"{outdir}/workflow.mp4"
    gif_path = f"{outdir}/workflow.gif"

    # Parse click events
    clicks, recording_start_ms = parse_events_log(events_log_path)

    # Validate raw video
    if not validate_raw_video(raw_path, outdir):
        # validate_raw_video handles salvage cases
        if os.path.exists(workflow_path):
            generate_gif_preview(outdir, workflow_path)
            apply_metadata_rename(outdir, workflow_path, gif_path)
            cleanup_temp_files(outdir)
        sys.exit(0)

    # Convert timestamps to relative time
    if clicks:
        first_ts = clicks[0][0]
        clicks = [(0.5 + (ts - first_ts) / 1000.0, x, y) for ts, x, y in clicks]
        log(f"Adjusted clicks: {clicks}")

    if clicks:
        # Add cursor overlay
        success = add_cursor_overlay_png(outdir, clicks)
        if not success:
            success = add_cursor_overlay_drawtext(outdir, clicks)

        if success:
            # Get video duration
            probe = subprocess.run([
                "ffprobe", "-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                f"{outdir}/with_cursor.mp4"
            ], capture_output=True, text=True)

            try:
                video_duration = float(probe.stdout.strip())
            except:
                video_duration = 30.0  # fallback

            log(f"Video duration: {video_duration:.1f}s")

            # Trim and speed up
            if trim_and_speedup(outdir, clicks, video_duration):
                os.remove(raw_path)
            else:
                # Fallback: just rename
                if os.path.exists(f"{outdir}/with_cursor.mp4"):
                    os.rename(f"{outdir}/with_cursor.mp4", workflow_path)
                else:
                    os.rename(raw_path, workflow_path)
        else:
            # Cursor overlay failed, just rename raw
            os.rename(raw_path, workflow_path)
    else:
        # No clicks
        process_no_clicks(outdir)

    # Validate final video
    if os.path.exists(workflow_path):
        probe = subprocess.run([
            "ffprobe", "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", workflow_path
        ], capture_output=True, text=True)

        if probe.returncode == 0:
            log(f"Final video duration: {probe.stdout.strip()}s")
        else:
            log(f"WARNING: Final video may be corrupted")
    else:
        log("ERROR: No output video created")

    # Generate GIF preview
    generate_gif_preview(outdir, workflow_path)

    # Apply metadata rename
    apply_metadata_rename(outdir, workflow_path, gif_path)

    # Cleanup
    cleanup_temp_files(outdir)

    log("Post-processing complete!")


if __name__ == "__main__":
    main()
`;
export const EVENTS_LOG_FILENAME = "events.log";

// Chrome DevTools Protocol port
const CDP_PORT = 39382;

// Active click listener WebSocket connection (kept open during recording)
let clickListenerWs: WebSocket | null = null;
let clickListenerCallback: ((x: number, y: number) => void) | null = null;

/**
 * Start listening for clicks via CDP console events.
 * This injects a click tracker that logs to console, and we listen for those logs.
 * Returns a cleanup function to stop listening.
 */
async function startClickListener(onClick: (x: number, y: number) => void): Promise<(() => void) | null> {
  try {
    const targetsResponse = await fetch(`http://0.0.0.0:${CDP_PORT}/json`);
    const targets = (await targetsResponse.json()) as Array<{
      type?: string;
      webSocketDebuggerUrl?: string;
    }>;
    const pageTarget = targets.find(
      (t) => t.type === "page" && t.webSocketDebuggerUrl
    );

    if (!pageTarget?.webSocketDebuggerUrl) {
      console.error("[startClickListener] No page target found");
      return null;
    }

    const wsUrl = pageTarget.webSocketDebuggerUrl;

    // Click tracking script - logs clicks to console with special prefix
    const clickTrackerScript = `
      if (!window.__clickTrackerV2) {
        window.__clickTrackerV2 = true;
        ['mousedown'].forEach(eventType => {
          document.addEventListener(eventType, (e) => {
            console.log('__CLICK_EVENT__', e.clientX, e.clientY, Date.now());
          }, true);
        });
      }
    `;

    return new Promise((resolve) => {
      const ws = new WebSocket(wsUrl);
      let msgId = 1;
      let setupComplete = false;

      clickListenerWs = ws;
      clickListenerCallback = onClick;

      const cleanup = () => {
        clickListenerWs = null;
        clickListenerCallback = null;
        try { ws.close(); } catch { /* ignore */ }
      };

      ws.addEventListener("open", () => {
        // Enable Runtime domain to receive console events
        ws.send(JSON.stringify({ id: msgId++, method: "Runtime.enable", params: {} }));
      });

      ws.addEventListener("message", (event) => {
        try {
          const msg = JSON.parse(String(event.data)) as {
            id?: number;
            method?: string;
            params?: {
              type?: string;
              args?: Array<{ type?: string; value?: unknown }>;
            };
          };

          // Setup sequence
          if (msg.id === 1) {
            // Runtime enabled, now enable Page
            ws.send(JSON.stringify({ id: msgId++, method: "Page.enable", params: {} }));
          } else if (msg.id === 2) {
            // Page enabled, add script for new documents
            ws.send(JSON.stringify({
              id: msgId++,
              method: "Page.addScriptToEvaluateOnNewDocument",
              params: { source: clickTrackerScript },
            }));
          } else if (msg.id === 3) {
            // Script added, run on current page too
            ws.send(JSON.stringify({
              id: msgId++,
              method: "Runtime.evaluate",
              params: { expression: clickTrackerScript },
            }));
          } else if (msg.id === 4) {
            // Setup complete
            setupComplete = true;
            console.log("[startClickListener] Click listener active");
            resolve(cleanup);
          }

          // Listen for console events (Runtime.consoleAPICalled)
          if (msg.method === "Runtime.consoleAPICalled" && msg.params?.type === "log") {
            const args = msg.params.args ?? [];
            // Check if this is our click event: __CLICK_EVENT__ x y timestamp
            if (args.length >= 3 && args[0]?.value === "__CLICK_EVENT__") {
              const x = typeof args[1]?.value === "number" ? args[1].value : 0;
              const y = typeof args[2]?.value === "number" ? args[2].value : 0;
              console.log(`[startClickListener] Received click at viewport (${x}, ${y})`);
              if (clickListenerCallback) {
                clickListenerCallback(x, y);
              }
            }
          }
        } catch (e) {
          console.error("[startClickListener] Error:", e);
        }
      });

      ws.addEventListener("error", (e) => {
        console.error("[startClickListener] WebSocket error:", e);
        if (!setupComplete) resolve(null);
      });

      ws.addEventListener("close", () => {
        console.log("[startClickListener] WebSocket closed");
        clickListenerWs = null;
      });

      // Timeout for setup
      setTimeout(() => {
        if (!setupComplete) {
          console.error("[startClickListener] Setup timeout");
          resolve(null);
        }
      }, 5000);
    });
  } catch (e) {
    console.error("[startClickListener] Exception:", e);
    return null;
  }
}

// Export startClickListener for use in prompt's post-processing script
export { startClickListener };

// Placeholder API key that signals to the proxy to use platform credits (Bedrock)
const CMUX_ANTHROPIC_PROXY_PLACEHOLDER_API_KEY = "sk_placeholder_cmux_anthropic_api_key";

// Directories for Claude Code configuration (matches main dashboard setup)
const CLAUDE_LIFECYCLE_DIR = "/root/lifecycle/claude";
const CLAUDE_SECRETS_DIR = `${CLAUDE_LIFECYCLE_DIR}/secrets`;
const CLAUDE_API_KEY_HELPER_PATH = `${CLAUDE_SECRETS_DIR}/anthropic_key_helper.sh`;
const CLAUDE_SETTINGS_PATH = "/root/.claude/settings.json";
const CLAUDE_CONFIG_DIR = path.dirname(CLAUDE_SETTINGS_PATH);

// Environment variables that should be unset to ensure Claude Code uses proxy-only auth
const CLAUDE_KEY_ENV_VARS_TO_UNSET = [
  "ANTHROPIC_AUTH_TOKEN",
  "CLAUDE_API_KEY",
];

/**
 * Sets up Claude Code configuration using the same approach as the main dashboard.
 * This writes settings.json with apiKeyHelper instead of using ANTHROPIC_API_KEY env var.
 */
async function setupClaudeCodeConfig(options: {
  anthropicBaseUrl: string;
  customHeaders: string;
  apiKey: string;
}): Promise<void> {
  const { anthropicBaseUrl, customHeaders, apiKey } = options;

  // Ensure directories exist
  await fs.mkdir(CLAUDE_SECRETS_DIR, { recursive: true });
  await fs.mkdir(path.dirname(CLAUDE_SETTINGS_PATH), { recursive: true });

  // Create the apiKeyHelper script (like main dashboard does)
  const helperScript = `#!/bin/sh
echo ${apiKey}`;
  await fs.writeFile(CLAUDE_API_KEY_HELPER_PATH, helperScript, { mode: 0o700 });

  // Create settings.json with apiKeyHelper and env block (like main dashboard does)
  const settingsConfig = {
    apiKeyHelper: CLAUDE_API_KEY_HELPER_PATH,
    env: {
      CLAUDE_CODE_ENABLE_TELEMETRY: 0,
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: 1,
      ANTHROPIC_BASE_URL: anthropicBaseUrl,
      ANTHROPIC_CUSTOM_HEADERS: customHeaders,
    },
  };

  await fs.writeFile(
    CLAUDE_SETTINGS_PATH,
    JSON.stringify(settingsConfig, null, 2),
    { mode: 0o644 }
  );

  await logToScreenshotCollector(
    `[setupClaudeCodeConfig] Created settings.json at ${CLAUDE_SETTINGS_PATH}`
  );
  await logToScreenshotCollector(
    `[setupClaudeCodeConfig] Created apiKeyHelper at ${CLAUDE_API_KEY_HELPER_PATH}`
  );
  await logToScreenshotCollector(
    `[setupClaudeCodeConfig] ANTHROPIC_BASE_URL: ${anthropicBaseUrl}`
  );
}

const IMAGE_EXTENSIONS = new Set([".png", ".jpg", ".jpeg", ".webp"]);
const VIDEO_EXTENSIONS = new Set([".mp4", ".webm", ".mkv", ".gif", ".apng"]);

function isScreenshotFile(fileName: string): boolean {
  return IMAGE_EXTENSIONS.has(path.extname(fileName).toLowerCase());
}

function isVideoFile(fileName: string): boolean {
  return VIDEO_EXTENSIONS.has(path.extname(fileName).toLowerCase());
}

// Files to exclude from screenshot collection (internal/temporary files)
const EXCLUDED_SCREENSHOT_FILES = new Set([
  "cursor.png", // Cursor overlay image for video processing
]);

// Files to exclude from video collection (internal/temporary files)
const EXCLUDED_VIDEO_FILES = new Set([
  "raw.mp4", // Raw recording before processing
  "with_cursor.mp4", // Intermediate video with cursor overlay
]);

async function collectMediaFiles(
  directory: string
): Promise<{ screenshots: string[]; videos: string[]; hasNestedDirectories: boolean }> {
  const entries = await fs.readdir(directory, { withFileTypes: true });
  const screenshots: string[] = [];
  const videos: string[] = [];
  let hasNestedDirectories = false;

  for (const entry of entries) {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      hasNestedDirectories = true;
      const nested = await collectMediaFiles(fullPath);
      screenshots.push(...nested.screenshots);
      videos.push(...nested.videos);
    } else if (entry.isFile()) {
      if (isScreenshotFile(entry.name) && !EXCLUDED_SCREENSHOT_FILES.has(entry.name)) {
        screenshots.push(fullPath);
      } else if (isVideoFile(entry.name) && !EXCLUDED_VIDEO_FILES.has(entry.name)) {
        videos.push(fullPath);
      }
    }
  }

  return { screenshots, videos, hasNestedDirectories };
}

type PostProcessResult = {
  exitCode: number | null;
  stdout: string;
  stderr: string;
};

const POST_PROCESS_LOG_LIMIT = 4000;

function trimPostProcessOutput(output: string): string {
  const trimmed = output.trim();
  if (trimmed.length <= POST_PROCESS_LOG_LIMIT) {
    return trimmed;
  }
  const overflow = trimmed.length - POST_PROCESS_LOG_LIMIT;
  return `${trimmed.slice(0, POST_PROCESS_LOG_LIMIT)}\n... [truncated ${overflow} chars]`;
}

async function runPostProcessScript(
  scriptPath: string,
  outputDir: string
): Promise<PostProcessResult> {
  return await new Promise<PostProcessResult>((resolve, reject) => {
    const child = spawn("python3", [scriptPath, outputDir], {
      cwd: outputDir,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";

    child.stdout?.on("data", (chunk: Buffer | string) => {
      stdout += chunk.toString();
    });

    child.stderr?.on("data", (chunk: Buffer | string) => {
      stderr += chunk.toString();
    });

    child.on("error", (error) => reject(error));
    child.on("close", (code) => {
      resolve({ exitCode: code, stdout, stderr });
    });
  });
}

async function postProcessVideos(outputDir: string): Promise<void> {
  const rawVideoPath = path.join(outputDir, "raw.mp4");
  try {
    await fs.access(rawVideoPath);
  } catch (error) {
    console.error("Post-process video check failed:", error);
    await logToScreenshotCollector(
      `[postProcessVideo] No raw.mp4 found at ${rawVideoPath}; skipping post-processing`
    );
    return;
  }

  const scriptPath = path.join(outputDir, "post_process_video.py");
  try {
    await fs.access(scriptPath);
  } catch (error) {
    console.error("Post-process script check failed:", error);
    await logToScreenshotCollector(
      `[postProcessVideo] post_process_video.py not found at ${scriptPath}; skipping post-processing`
    );
    return;
  }

  await logToScreenshotCollector(
    `[postProcessVideo] Starting post-processing for ${outputDir}`
  );

  try {
    const result = await runPostProcessScript(scriptPath, outputDir);
    const trimmedStdout = trimPostProcessOutput(result.stdout);
    const trimmedStderr = trimPostProcessOutput(result.stderr);

    if (trimmedStdout) {
      await logToScreenshotCollector(`[postProcessVideo] stdout:\n${trimmedStdout}`);
    }
    if (trimmedStderr) {
      await logToScreenshotCollector(`[postProcessVideo] stderr:\n${trimmedStderr}`);
    }

    if (result.exitCode !== 0) {
      await logToScreenshotCollector(
        `[postProcessVideo] Failed with exit code ${result.exitCode ?? "unknown"}`
      );
      console.error(
        "Post-process video failed:",
        result.exitCode ?? "unknown exit code"
      );
    } else {
      await logToScreenshotCollector(
        `[postProcessVideo] Completed successfully`
      );
    }
  } catch (error) {
    console.error("Post-process video execution failed:", error);
    await logToScreenshotCollector(
      `[postProcessVideo] Execution failed: ${error instanceof Error ? error.message : String(error)}`
    );
  }
}

export function normalizeScreenshotOutputDir(outputDir: string): string {
  if (path.isAbsolute(outputDir)) {
    return path.normalize(outputDir);
  }
  return path.resolve(SCREENSHOT_STORAGE_ROOT, outputDir);
}

export type ClaudeCodeAuthConfig =
  | { auth: { taskRunJwt: string } }
  | { auth: { anthropicApiKey: string } };

type BranchBaseOptions = {
  workspaceDir: string;
  changedFiles: string[];
  prTitle: string;
  prDescription: string;
  outputDir: string;
  pathToClaudeCodeExecutable?: string;
  /** Combined setup script (maintenance + dev), if provided */
  setupScript?: string;
  /** Command to install dependencies (e.g., "bun install", "npm install") */
  installCommand?: string;
  /** Command to start the dev server (e.g., "bun run dev", "npm run dev") */
  devCommand?: string;
  convexSiteUrl?: string;
};

type BranchCaptureOptions =
  | (BranchBaseOptions & { branch: string; auth: { taskRunJwt: string } })
  | (BranchBaseOptions & { branch: string; auth: { anthropicApiKey: string } });

type CaptureScreenshotsBaseOptions = BranchBaseOptions & {
  baseBranch: string;
  headBranch: string;
};

export type CaptureScreenshotsOptions =
  | (CaptureScreenshotsBaseOptions & { auth: { taskRunJwt: string } })
  | (CaptureScreenshotsBaseOptions & { auth: { anthropicApiKey: string } });

export interface ScreenshotResult {
  status: "completed" | "failed" | "skipped";
  screenshots?: { path: string; description?: string }[];
  videos?: { path: string; description?: string }[];
  hasUiChanges?: boolean;
  error?: string;
  reason?: string;
}

/**
 * Use Claude Agent SDK with Playwright MCP to capture screenshots
 * Assumes the workspace is already set up with the correct branch checked out
 */
function isTaskRunJwtAuth(
  auth: ClaudeCodeAuthConfig["auth"]
): auth is { taskRunJwt: string } {
  return "taskRunJwt" in auth;
}

function log(
  level: "INFO" | "WARN" | "ERROR",
  message: string,
  data?: Record<string, unknown>
): void {
  const logData = data ? ` ${JSON.stringify(data)}` : "";
  console.log(`[${level}] ${message}${logData}`);
}

function formatOptionalValue(value: string | null | undefined): string {
  const trimmed = value?.trim();
  return trimmed ? trimmed : "<unset>";
}

export async function captureScreenshotsForBranch(
  options: BranchCaptureOptions
): Promise<{
  screenshots: { path: string; description?: string }[];
  videos: { path: string; description?: string }[];
  hasUiChanges?: boolean;
}> {
  const {
    workspaceDir,
    changedFiles,
    prTitle,
    prDescription,
    branch,
    outputDir: requestedOutputDir,
    auth,
    setupScript,
    installCommand,
    devCommand,
    convexSiteUrl,
  } = options;
  const outputDir = normalizeScreenshotOutputDir(requestedOutputDir);
  const useTaskRunJwt = isTaskRunJwtAuth(auth);

  if (!useTaskRunJwt) {
    await logToScreenshotCollector(
      "[ERROR] Direct Anthropic API key auth is disabled for screenshot collection. Provide taskRunJwt."
    );
    throw new Error(
      "Direct Anthropic API key auth is disabled for screenshot collection."
    );
  }

  if (!convexSiteUrl) {
    await logToScreenshotCollector(
      "[ERROR] convexSiteUrl is required for proxy-only screenshot collection."
    );
    throw new Error("convexSiteUrl is required for proxy-only screenshot collection.");
  }

  const devInstructions = (() => {
    const normalizedSetupScript = setupScript?.trim() ?? "";
    const fallbackSetupScript = [installCommand?.trim(), devCommand?.trim()]
      .filter(Boolean)
      .join("\n\n");
    const resolvedSetupScript = normalizedSetupScript || fallbackSetupScript;

    if (resolvedSetupScript) {
      return `
The user provided the following setup script (maintenance + dev combined). If no dev server is running, use this script to start it:
<setup_script>
${resolvedSetupScript}
</setup_script>`;
    }

    if (!installCommand && !devCommand) {
      return `
The user did not provide installation or dev commands. You will need to discover them by reading README.md, package.json, .devcontainer.json, or other configuration files.`;
    }
    const parts = ["The user provided the following commands:"];
    if (installCommand) {
      parts.push(`<install_command>\n${installCommand}\n</install_command>`);
    } else {
      parts.push(
        "(No install command provided - check README.md or package.json)"
      );
    }
    if (devCommand) {
      parts.push(`<dev_command>\n${devCommand}\n</dev_command>`);
    } else {
      parts.push(
        "(No dev command provided - check README.md or package.json)"
      );
    }
    return "\n" + parts.join("\n");
  })();

  const prompt = `You are a screenshot collector for pull request reviews. Your job is to determine if a PR contains UI changes and, if so, capture screenshots of those changes.

CRITICAL: IF UI CHANGES EXIST, YOU MUST CAPTURE THEM
If you determine the PR has UI changes, you MUST capture at least one screenshot or video before ending.
Do NOT say "let me capture X" and then end - actually capture it.
Do NOT end after just analyzing files - if there are UI changes, continue to capture them.

<PR_CONTEXT>
Title: ${prTitle}
Description: ${prDescription || "No description provided"}
Branch: ${branch}
Files changed:
${changedFiles.map((f) => `- ${f}`).join("\n")}
</PR_CONTEXT>

<ENVIRONMENT>
Working directory: ${workspaceDir}
Screenshot output directory: ${outputDir}
${devInstructions}
</ENVIRONMENT>

<PHASE_1_ANALYSIS>
First, analyze the changed files to determine if this PR contains UI changes.

IMPORTANT: Base your decision on the ACTUAL FILES CHANGED, not the PR title or description. PR descriptions can be misleading or incomplete. If the diff contains UI-affecting code, there ARE UI changes regardless of what the description says.

UI changes ARE present if the PR modifies code that affects what users see in the browser:
- Frontend components or templates (any framework: React, Vue, Rails ERB, PHP Blade, Django templates, etc.)
- Stylesheets (CSS, SCSS, Tailwind, styled-components, etc.)
- Markup or template files (HTML, JSX, ERB, Twig, Jinja, Handlebars, etc.)
- Client-side JavaScript/TypeScript that affects rendering
- UI states like loading indicators, error messages, empty states, or toasts
- Accessibility attributes, ARIA labels, or semantic markup

UI changes are NOT present if the PR only modifies:
- Server-side logic that doesn't change what's rendered (API handlers, database queries, background jobs)
- Configuration files (unless they affect theming or UI behavior)
- Tests, documentation, or build scripts
- Type definitions or interfaces for non-UI code

If no UI changes exist: Set hasUiChanges=false, take ZERO screenshots, and explain why. Do not start the dev server or open a browser.
</PHASE_1_ANALYSIS>

<PHASE_2_CAPTURE>
If UI changes exist, capture screenshots:

1. FIRST, check if the dev server is ALREADY RUNNING:
   - Run \`tmux list-windows\` and \`tmux capture-pane -p -t <window>\` to see running processes and their logs
   - Check if there's a dev server process starting up or already running in any tmux window
   - For cloud tasks, also inspect cmux-pty output/logs (tmux may not be used). Look for active dev server commands there.
   - The dev server is typically started automatically in this environment - BE PATIENT and monitor the logs
   - If you see the server is starting/compiling, WAIT for it to finish - do NOT kill it or restart it
   - Use \`ss -tlnp | grep LISTEN\` to see what ports have servers listening
2. ONLY if no server is running anywhere: Read CLAUDE.md, README.md, or package.json for setup instructions. Install dependencies if needed, then start the dev server.
3. BE PATIENT - servers can take time to compile. Monitor tmux logs to see progress. A response from curl (even 404) means the server is up. Do NOT restart the server if it's still compiling.
4. Navigate to the pages/components modified in the PR
5. Capture screenshots of the changes, including:
   - The default/resting state of changed components
   - Interactive states: hover, focus, active, disabled
   - Conditional states: loading, error, empty, success (if the PR modifies these!)
   - Hidden UI: modals, dropdowns, tooltips, accordions
   - Responsive layouts if the PR includes responsive changes
6. Save screenshots to ${outputDir} with descriptive names like "component-state-${branch}.png"
</PHASE_2_CAPTURE>

<PHASE_3_QUALITY_VERIFICATION>
After capturing screenshots, you MUST verify each one for quality. For EACH screenshot file in ${outputDir}:

1. OPEN the screenshot image file and visually inspect it
2. EVALUATE the screenshot against these quality criteria:
   - Does it show the intended UI component/page that the filename suggests?
   - Is the content fully loaded (no spinners, skeleton loaders, or partial renders - unless that IS the intended capture)?
   - Is the relevant UI element fully visible and not cut off?
   - Is the screenshot free of error states, console overlays, or dev tool artifacts (unless intentionally capturing those)?
   - Does it accurately represent the PR changes you intended to capture?

3. DECIDE: Is this a good screenshot?
   - GOOD: The screenshot clearly captures the intended UI state. Keep it.
   - BAD: The screenshot is blurry, shows wrong content, has unintended loading states, is cut off, or doesn't represent the PR changes. DELETE IT.

4. If BAD: Delete the screenshot file from the filesystem using \`rm <filepath>\`. Then either:
   - Retake the screenshot after fixing the issue (refresh page, wait for content to load, scroll to element, resize viewport)
   - Skip if the UI state cannot be reproduced

5. Only include screenshots in your final output that you have verified as GOOD quality.

Be ruthless about quality. A few excellent screenshots are far more valuable than many mediocre ones. Delete anything that doesn't clearly demonstrate the UI changes.
</PHASE_3_QUALITY_VERIFICATION>

<WHAT_TO_CAPTURE>
Screenshot the UI states that the PR actually modifies. Be intentional:

- If the PR changes a loading spinner -> screenshot the loading state
- If the PR changes error handling UI -> screenshot the error state
- If the PR changes a skeleton loader -> screenshot the skeleton
- If the PR changes hover styles -> screenshot the hover state
- If the PR changes a modal -> open and screenshot the modal

Don't screenshot loading/error states incidentally while waiting for the "real" UI. Screenshot them when they ARE the change.
</WHAT_TO_CAPTURE>

<CRITICAL_MISTAKES>
Avoid these failure modes:

FALSE POSITIVE: Taking screenshots when the PR has no UI changes. Backend-only, config, or test changes = hasUiChanges=false, zero screenshots.

FALSE NEGATIVE: Failing to capture screenshots when UI changes exist. If React components, CSS, or templates changed, you MUST capture them.

FAKE UI: Creating mock HTML files instead of screenshotting the real app. Never fabricate UIs. If the dev server won't start, report the failure.

WRONG PAGE: Screenshotting pages unrelated to the PR. Only capture components/pages that the changed files actually render.

DUPLICATE SCREENSHOTS: Taking multiple identical screenshots. Each screenshot should show something distinct.

INCOMPLETE CAPTURE: Missing important UI elements. Ensure full components are visible and not cut off.
</CRITICAL_MISTAKES>

<VIDEO_RECORDING>
Record screen videos to demonstrate COMPLETE WORKFLOWS end-to-end. Cursor overlay is added automatically in post-processing.

YOU MUST RECORD A VIDEO IF:
- There is a button, link, or clickable element
- There is navigation or page transitions
- There is any UI flow or state change
- The PR adds/modifies interactive elements

Screenshots alone are NOT enough for interactive changes - you MUST record a video showing the interaction.

SKIP VIDEO ONLY FOR: pure styling changes (colors, fonts, spacing), static text-only changes

CRITICAL - SHOW COMPLETE INTERACTIONS:
- DO NOT just hover over elements - CLICK them
- After clicking a button, WAIT for and RECORD the result (loading state, modal, page change, toast, etc.)
- If a button opens a modal, record: click button -> modal appears -> interact with modal content
- If a button triggers an action, record: click button -> see the result/feedback
- Wait 1-2 seconds after each significant UI change to capture the result clearly
- The goal is to show reviewers what HAPPENS when users interact, not just what can be clicked

STEP 1 - WRITE VIDEO METADATA:
Before recording, write a video-metadata.json file describing what the video will demonstrate.
Use echo to write the JSON - replace the placeholder values with your actual filename and description:
\`\`\`bash
echo '{"fileName": "YOUR-KEBAB-CASE-FILENAME", "description": "YOUR DESCRIPTION HERE"}' > "${outputDir}/video-metadata.json"
\`\`\`

For fileName, use kebab-case (no extension) like:
- "submit-button-success-toast"
- "login-validation-error"
- "dropdown-navigation"
- "modal-open-close"

For description, explain what the video demonstrates:
- What element is clicked/interacted with
- What result is shown (modal opens, toast appears, page navigates, etc.)

Example:
\`\`\`bash
echo '{"fileName": "cnn-link-button-click", "description": "Clicking the CNN link button navigates to the CNN website"}' > "${outputDir}/video-metadata.json"
\`\`\`

STEP 2 - TAKE FRESH SNAPSHOT:
ALWAYS take a fresh snapshot immediately before starting the recording. Old snapshots go stale (uids become invalid). Do this right before ffmpeg:
\`\`\`
take_snapshot
\`\`\`

STEP 3 - START RECORDING:
\`\`\`bash
DISPLAY=:1 ffmpeg -y -f x11grab -draw_mouse 0 -framerate 24 -video_size 1920x1080 -i :1+0,0 -c:v libx264 -preset ultrafast -crf 26 -pix_fmt yuv420p -movflags +frag_keyframe+empty_moov "${outputDir}/raw.mp4" &
FFMPEG_PID=$!
sleep 0.3
\`\`\`

STEP 4 - CLICK ELEMENTS AND SHOW RESULTS:
Click elements using their uid from the fresh snapshot. The cursor position is captured automatically.
The cursor overlay starts at screen center and animates to each click position.

IMPORTANT: After clicking, WAIT for the UI to respond before ending the recording:
- Wait for modals/dialogs to fully appear
- Wait for loading spinners to complete
- Wait for success/error messages to show
- Wait for page transitions to finish
- Add sleep commands (sleep 1 or sleep 2) after clicks to capture the result

CRITICAL - AFTER CLICKING, YOU MUST COMPLETE STEP 5
The video is NOT VALID until recording is stopped and post-processing runs automatically.
- Do NOT end the session after clicking
- Do NOT call list_pages or select_page after clicking
- You MUST run STEP 5 to stop recording; post-processing runs automatically after you finish

STEP 5 - STOP RECORDING (run this first):
\`\`\`bash
kill -INT $FFMPEG_PID 2>/dev/null; sleep 2; wait $FFMPEG_PID 2>/dev/null
\`\`\`

STEP 6 - POST-PROCESS VIDEO (automatic - no action required):
Post-processing runs automatically after you finish. Do NOT run post_process_video.py manually.

CRITICAL WORKFLOW - YOU MUST FOLLOW THIS EXACTLY:
1. Write video metadata (step 1) - describe what you're about to record
2. Take fresh snapshot (step 2)
3. Start ffmpeg recording (step 3)
4. Click elements to demonstrate the UI (step 4)
5. STOP the recording (step 5) - wait for ffmpeg to finish
6. Post-processing runs automatically after you finish - do NOT run it yourself
7. Only THEN can you end - the video is INVALID without post-processing

DO NOT:
- Run post_process_video.py manually (it runs automatically after you finish)
- Call list_pages or select_page after clicking
- Skip any step - the video will be corrupted
</VIDEO_RECORDING>

<COMPLETION_REQUIREMENTS>
If you determined the PR has NO UI changes:
- You may end after stating "No UI changes detected" - no screenshots needed.

If you determined the PR HAS UI changes:
- You MUST capture at least one screenshot or video before ending.
- DO NOT just plan what to do - EXECUTE the plan.
- DO NOT say "let me do X" and then stop - actually DO X.
- If you're about to end without capturing anything, STOP and capture first.
</COMPLETION_REQUIREMENTS>

<OUTPUT>
After capturing screenshots/videos, briefly state what you captured and leave the browser open.
</OUTPUT>`;

  await logToScreenshotCollector(
    `Starting Claude Agent with browser MCP for branch: ${branch}`
  );

  const screenshotPaths: string[] = [];
  const videoPaths: string[] = [];

  // Convert .convex.cloud to .convex.site for HTTP endpoints
  // HTTP routes are served from .convex.site, not .convex.cloud
  const normalizedConvexSiteUrl = formatOptionalValue(convexSiteUrl)
    .replace(".convex.cloud", ".convex.site");

  const anthropicBaseUrl = `${normalizedConvexSiteUrl}/api/anthropic`;

  try {
    const hadOriginalApiKey = Object.prototype.hasOwnProperty.call(
      process.env,
      "ANTHROPIC_API_KEY"
    );
    const originalApiKey = process.env.ANTHROPIC_API_KEY;
    delete process.env.ANTHROPIC_API_KEY;

    // Also delete OAuth token from process.env BEFORE creating claudeEnv
    // This prevents Claude Code from bypassing ANTHROPIC_BASE_URL
    const hadOriginalOAuthToken = Object.prototype.hasOwnProperty.call(
      process.env,
      "CLAUDE_CODE_OAUTH_TOKEN"
    );
    const originalOAuthToken = process.env.CLAUDE_CODE_OAUTH_TOKEN;
    delete process.env.CLAUDE_CODE_OAUTH_TOKEN;
    await logToScreenshotCollector(`ANTHROPIC_BASE_URL: ${anthropicBaseUrl}`);

    const claudeEnv: NodeJS.ProcessEnv = {
      ...process.env,
      IS_SANDBOX: "1",
      // Don't set CLAUDE_CONFIG_DIR - we use settingSources: [] to ignore config files
      CLAUDE_CODE_ENABLE_TELEMETRY: "0",
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
      // Ensure HOME and USER are set (required by Claude CLI, may be missing in sandbox)
      HOME: process.env.HOME || "/root",
      USER: process.env.USER || "root",
    };

    // Remove environment variables that may interfere with our configured auth path.
    // CLAUDE_CODE_OAUTH_TOKEN: If present, Claude Code may bypass ANTHROPIC_BASE_URL and go direct to Anthropic.
    // AWS_*: These can cause Claude Code to use Bedrock directly instead of our proxy.
    // ANTHROPIC_MODEL/SMALL_FAST_MODEL: We want Claude Code to use its defaults, not inherited values.
    delete claudeEnv.CLAUDE_CODE_OAUTH_TOKEN;
    delete claudeEnv.AWS_BEARER_TOKEN_BEDROCK;
    delete claudeEnv.CLAUDE_CODE_USE_BEDROCK;
    delete claudeEnv.ANTHROPIC_MODEL;
    delete claudeEnv.ANTHROPIC_SMALL_FAST_MODEL;
    // Remove AWS credentials that could cause Claude Code to bypass our proxy
    delete claudeEnv.AWS_ACCESS_KEY_ID;
    delete claudeEnv.AWS_SECRET_ACCESS_KEY;
    delete claudeEnv.AWS_SESSION_TOKEN;
    delete claudeEnv.AWS_REGION;
    delete claudeEnv.AWS_DEFAULT_REGION;
    delete claudeEnv.AWS_PROFILE;

    // Configure proxy auth via env vars (works both locally and in sandbox)
    // We use settingSources: [] to ignore user/project settings, so env vars take precedence
    const customHeaders = `x-cmux-token:${auth.taskRunJwt}\nx-cmux-source:screenshot-collector`;

    // Unset any conflicting auth variables first
    for (const envVar of CLAUDE_KEY_ENV_VARS_TO_UNSET) {
      delete claudeEnv[envVar];
    }

    // Set proxy env vars
    claudeEnv.ANTHROPIC_BASE_URL = anthropicBaseUrl;
    claudeEnv.ANTHROPIC_CUSTOM_HEADERS = customHeaders;
    claudeEnv.ANTHROPIC_API_KEY = CMUX_ANTHROPIC_PROXY_PLACEHOLDER_API_KEY;

    let detectedHasUiChanges: boolean | undefined;

    // Write trajectory to JSONL file for post-processing (video cursor overlay)
    const trajectoryPath = path.join(outputDir, "trajectory.jsonl");
    const trajectoryStream = await fs.open(trajectoryPath, "w");

    // Events log for pretool hook - logs tool calls with uid and bounding rects
    const eventsLogPath = path.join(outputDir, EVENTS_LOG_FILENAME);
    // Clear/create events.log at start
    await fs.writeFile(eventsLogPath, "");

    // Write post-processing script to disk for video processing
    const postProcessScriptPath = path.join(outputDir, "post_process_video.py");
    await fs.writeFile(postProcessScriptPath, POST_PROCESS_VIDEO_SCRIPT, { mode: 0o755 });
    await logToScreenshotCollector(`[setupPostProcessScript] Wrote post_process_video.py to ${postProcessScriptPath}`);

    // Click listener cleanup function
    let stopClickListener: (() => void) | null = null;

    try {
      for await (const message of query({
        prompt,
        options: {
          model: "claude-opus-4-5-20251101",
          mcpServers: {
            chrome: {
              command: "bunx",
              args: [
                "chrome-devtools-mcp",
                "--browserUrl",
                "http://0.0.0.0:39382",
              ],
            },
          },
          allowDangerouslySkipPermissions: true,
          permissionMode: "bypassPermissions",
          cwd: workspaceDir,
          pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
          // Empty array = SDK isolation mode, disables loading user/project settings
          // This ensures env vars (ANTHROPIC_BASE_URL, etc.) are used instead of ~/.claude/settings.json
          settingSources: [],
          env: claudeEnv,
          stderr: (data) =>
            logToScreenshotCollector(`[claude-code-stderr] ${data}`),
        },
      })) {
        // Write message to trajectory JSONL with timestamp
        const timestamp = Date.now();
        const trajectoryEntry = {
          timestamp,
          message,
        };
        await trajectoryStream.write(JSON.stringify(trajectoryEntry) + "\n");

        // HOOK: Track mouse clicks via CDP for video cursor overlay
        if (message.type === "assistant") {
          const content = message.message?.content;
          if (Array.isArray(content)) {
            for (const block of content) {
              if (
                block &&
                typeof block === "object" &&
                "type" in block &&
                block.type === "tool_use" &&
                "name" in block
              ) {
                const toolName = String(block.name);
                const input = "input" in block && block.input && typeof block.input === "object"
                  ? block.input as Record<string, unknown>
                  : {};

                // Detect Bash commands for ffmpeg recording
                if (toolName === "Bash" && typeof input.command === "string") {
                  const cmd = input.command;

                  // Recording start: start streaming click listener
                  if (cmd.includes("ffmpeg") && cmd.includes("x11grab")) {
                    const BROWSER_CHROME_OFFSET = 85;

                    // Start click listener that streams events to us via CDP console
                    stopClickListener = await startClickListener(async (viewportX, viewportY) => {
                      // Convert viewport coords to screen coords
                      const screenX = viewportX;
                      const screenY = viewportY + BROWSER_CHROME_OFFSET;

                      await fs.appendFile(
                        eventsLogPath,
                        JSON.stringify({
                          timestamp: Date.now(),
                          event: "click",
                          x: Math.round(screenX),
                          y: Math.round(screenY),
                        }) + "\n"
                      );
                    });

                    // Log recording start
                    await fs.appendFile(
                      eventsLogPath,
                      JSON.stringify({
                        timestamp,
                        event: "recording_start",
                      }) + "\n"
                    );
                  }

                  // Recording stop: stop click listener when ffmpeg is killed
                  if (cmd.includes("kill") && cmd.includes("-INT")) {
                    if (stopClickListener) {
                      stopClickListener();
                      stopClickListener = null;
                    }
                  }
                }
              }
            }
          }
        }

        // Format and log all message types
        const formatted = formatClaudeMessage(message);
        if (formatted) {
          await logToScreenshotCollector(formatted);
        }

        // Extract hasUiChanges from result message
        if (message.type === "result") {
          // Try to parse hasUiChanges from the result text
          // Claude may express this as "hasUiChanges=false", "hasUiChanges: false", or in JSON
          if ("result" in message && typeof message.result === "string") {
            const resultText = message.result.toLowerCase();
            // Check for explicit false indicators
            if (
              resultText.includes("hasuichanges=false") ||
              resultText.includes("hasuichanges: false") ||
              resultText.includes("hasuichanges\":false") ||
              resultText.includes("hasuichanges\": false") ||
              resultText.includes("no ui changes") ||
              resultText.includes("no visual changes") ||
              resultText.includes("backend-only") ||
              resultText.includes("does not contain ui changes")
            ) {
              detectedHasUiChanges = false;
            } else if (
              resultText.includes("hasuichanges=true") ||
              resultText.includes("hasuichanges: true") ||
              resultText.includes("hasuichanges\":true") ||
              resultText.includes("hasuichanges\": true") ||
              resultText.includes("captured") ||
              resultText.includes("screenshot")
            ) {
              detectedHasUiChanges = true;
            }
          }
        }
      }
    } catch (error) {
      await logToScreenshotCollector(
        `Failed to capture screenshots with Claude Agent: ${error instanceof Error ? error.message : String(error)}`
      );
      log("ERROR", "Failed to capture screenshots with Claude Agent", {
        error: error instanceof Error ? error.message : String(error),
      });
      throw error;
    } finally {
      // Stop click listener if still running
      if (stopClickListener) {
        stopClickListener();
        stopClickListener = null;
      }

      // Close trajectory stream
      await trajectoryStream.close();

      // Post-process any recorded videos after the agent stops
      await postProcessVideos(outputDir);

      // Restore original API key
      if (hadOriginalApiKey) {
        if (originalApiKey !== undefined) {
          process.env.ANTHROPIC_API_KEY = originalApiKey;
        } else {
          delete process.env.ANTHROPIC_API_KEY;
        }
      } else {
        delete process.env.ANTHROPIC_API_KEY;
      }
      // Restore original OAuth token
      if (hadOriginalOAuthToken) {
        if (originalOAuthToken !== undefined) {
          process.env.CLAUDE_CODE_OAUTH_TOKEN = originalOAuthToken;
        } else {
          delete process.env.CLAUDE_CODE_OAUTH_TOKEN;
        }
      } else {
        delete process.env.CLAUDE_CODE_OAUTH_TOKEN;
      }
    }

    // Find all screenshot and video files in the output directory
    try {
      const { screenshots, videos, hasNestedDirectories } =
        await collectMediaFiles(outputDir);

      if (hasNestedDirectories) {
        await logToScreenshotCollector(
          `Detected nested media folders under ${outputDir}. Please keep all screenshots and videos directly in the output directory.`
        );
      }

      const uniqueScreens = Array.from(
        new Set(screenshots.map((filePath) => path.normalize(filePath)))
      ).sort();
      screenshotPaths.push(...uniqueScreens);

      const uniqueVideos = Array.from(
        new Set(videos.map((filePath) => path.normalize(filePath)))
      ).sort();
      videoPaths.push(...uniqueVideos);
    } catch (readError) {
      log("WARN", "Could not read output directory", {
        outputDir,
        error:
          readError instanceof Error ? readError.message : String(readError),
      });
    }

    // Helper to generate description from filename
    const generateDescriptionFromFileName = (filePath: string): string => {
      const fileName = path.basename(filePath);
      // Remove extension and branch suffix (e.g., "-cmux-branch-xyz123.png")
      const nameWithoutExt = fileName.replace(/\.[^.]+$/, "");
      // Remove the branch/random suffix (typically last hyphen-separated segment with random chars)
      const parts = nameWithoutExt.split("-");
      // Remove last part if it looks like a random ID (short alphanumeric)
      if (parts.length > 1 && /^[a-z0-9]{5,8}$/i.test(parts[parts.length - 1] || "")) {
        parts.pop();
      }
      // Remove "cmux" prefix parts if present
      const filteredParts = parts.filter(p => !p.toLowerCase().startsWith("cmux"));
      // Convert remaining parts to readable description
      const description = filteredParts
        .join(" ")
        .replace(/_/g, " ")
        .replace(/\s+/g, " ")
        .trim();
      // Capitalize first letter of each word
      return description
        .split(" ")
        .map(word => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase())
        .join(" ");
    };

    const screenshotsWithDescriptions = screenshotPaths.map((absolutePath) => {
      const description = generateDescriptionFromFileName(absolutePath);
      return {
        path: absolutePath,
        description: description || undefined,
      };
    });

    // Try to read video metadata for descriptions
    let videoMetadata: { fileName?: string; description?: string } | null = null;
    const metadataPath = path.join(outputDir, "video-metadata.json");
    try {
      const metadataContent = await fs.readFile(metadataPath, "utf-8");
      videoMetadata = JSON.parse(metadataContent);
      log("INFO", "Read video metadata", { metadata: videoMetadata });
    } catch {
      // No metadata file or invalid JSON - that's fine, we'll generate descriptions
    }

    const videosWithDescriptions = videoPaths.map((absolutePath) => {
      const fileName = path.basename(absolutePath);
      const fileNameWithoutExt = fileName.replace(/\.[^.]+$/, "");

      // Check if this video matches the metadata filename (with or without extension)
      const metadataFileName = videoMetadata?.fileName?.replace(/\.[^.]+$/, "");
      const hasMatchingMetadata = metadataFileName &&
        (fileNameWithoutExt === metadataFileName ||
         fileNameWithoutExt.toLowerCase() === metadataFileName.toLowerCase());

      // Use metadata description if available and filename matches
      let description: string;
      if (hasMatchingMetadata && videoMetadata?.description) {
        description = videoMetadata.description;
      } else {
        // Fall back to generated description from filename
        description = generateDescriptionFromFileName(absolutePath);
      }

      return {
        path: absolutePath,
        description: description || undefined,
      };
    });

    // Determine hasUiChanges:
    // 1. Use explicitly detected value from Claude's result
    // 2. If we have screenshots/videos, UI changes exist
    // 3. Otherwise, leave undefined (caller can decide)
    let finalHasUiChanges = detectedHasUiChanges;
    if (finalHasUiChanges === undefined && (screenshotsWithDescriptions.length > 0 || videosWithDescriptions.length > 0)) {
      finalHasUiChanges = true;
    }

    return {
      screenshots: screenshotsWithDescriptions,
      videos: videosWithDescriptions,
      hasUiChanges: finalHasUiChanges,
    };
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "unknown error");
    await logToScreenshotCollector(
      `Failed to capture screenshots with Claude Agent: ${message}`
    );
    console.error("Screenshot capture error:", error);
    throw error;
  }
}

/**
 * Capture screenshots for a PR
 * Assumes the workspace directory is already set up with git repo cloned
 */
export async function claudeCodeCapturePRScreenshots(
  options: CaptureScreenshotsOptions
): Promise<ScreenshotResult> {
  const {
    workspaceDir,
    changedFiles,
    prTitle,
    prDescription,
    baseBranch,
    headBranch,
    outputDir: requestedOutputDir,
    auth,
  } = options;
  const outputDir = normalizeScreenshotOutputDir(requestedOutputDir);

  try {
    await logToScreenshotCollector(
      `Starting PR screenshot capture in ${workspaceDir}`
    );

    if (changedFiles.length === 0) {
      const reason = "No files changed in PR";
      await logToScreenshotCollector(reason);
      return { status: "skipped", reason };
    }

    await logToScreenshotCollector(
      `Found ${changedFiles.length} changed files: ${changedFiles.join(", ")}`
    );

    await fs.mkdir(outputDir, { recursive: true });

    const allScreenshots: { path: string; description?: string }[] = [];
    const allVideos: { path: string; description?: string }[] = [];
    let hasUiChanges: boolean | undefined;

    const CAPTURE_BEFORE = false;

    if (CAPTURE_BEFORE) {
      // Capture screenshots for base branch (before changes)
      await logToScreenshotCollector(
        `Capturing 'before' screenshots for base branch: ${baseBranch}`
      );
      const beforeCapture = await captureScreenshotsForBranch(
        isTaskRunJwtAuth(auth)
          ? {
            workspaceDir,
            changedFiles,
            prTitle,
            prDescription,
            branch: baseBranch,
            outputDir,
            auth: { taskRunJwt: auth.taskRunJwt },
            pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
            setupScript: options.setupScript,
            installCommand: options.installCommand,
            devCommand: options.devCommand,
            convexSiteUrl: options.convexSiteUrl,
          }
          : {
            workspaceDir,
            changedFiles,
            prTitle,
            prDescription,
            branch: baseBranch,
            outputDir,
            auth: { anthropicApiKey: auth.anthropicApiKey },
            pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
            setupScript: options.setupScript,
            installCommand: options.installCommand,
            devCommand: options.devCommand,
            convexSiteUrl: options.convexSiteUrl,
          }
      );
      allScreenshots.push(...beforeCapture.screenshots);
      allVideos.push(...beforeCapture.videos);
      if (beforeCapture.hasUiChanges !== undefined) {
        hasUiChanges = beforeCapture.hasUiChanges;
      }
      await logToScreenshotCollector(
        `Captured ${beforeCapture.screenshots.length} 'before' screenshots and ${beforeCapture.videos.length} videos`
      );
    }

    // Capture screenshots for head branch (after changes)
    await logToScreenshotCollector(
      `Capturing 'after' screenshots for head branch: ${headBranch}`
    );
    const afterCapture = await captureScreenshotsForBranch(
      isTaskRunJwtAuth(auth)
        ? {
          workspaceDir,
          changedFiles,
          prTitle,
          prDescription,
          branch: headBranch,
          outputDir,
          auth: { taskRunJwt: auth.taskRunJwt },
          pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
          setupScript: options.setupScript,
          installCommand: options.installCommand,
          devCommand: options.devCommand,
          convexSiteUrl: options.convexSiteUrl,
        }
        : {
          workspaceDir,
          changedFiles,
          prTitle,
          prDescription,
          branch: headBranch,
          outputDir,
          auth: { anthropicApiKey: auth.anthropicApiKey },
          pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
          setupScript: options.setupScript,
          installCommand: options.installCommand,
          devCommand: options.devCommand,
          convexSiteUrl: options.convexSiteUrl,
        }
    );
    allScreenshots.push(...afterCapture.screenshots);
    allVideos.push(...afterCapture.videos);
    if (afterCapture.hasUiChanges !== undefined) {
      hasUiChanges = afterCapture.hasUiChanges;
    }
    await logToScreenshotCollector(
      `Captured ${afterCapture.screenshots.length} 'after' screenshots and ${afterCapture.videos.length} videos`
    );

    await logToScreenshotCollector(
      `Capture completed. Total: ${allScreenshots.length} screenshots, ${allVideos.length} videos saved to ${outputDir}`
    );
    log("INFO", "PR capture completed", {
      screenshotCount: allScreenshots.length,
      videoCount: allVideos.length,
      outputDir,
    });

    return {
      status: "completed",
      screenshots: allScreenshots,
      videos: allVideos,
      hasUiChanges,
    };
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "unknown error");
    await logToScreenshotCollector(`PR screenshot capture failed: ${message}`);
    log("ERROR", "PR screenshot capture failed", {
      error: message,
    });
    return {
      status: "failed",
      error: message,
    };
  }
}

// Re-export utilities
export { logToScreenshotCollector } from "./logger";
export { formatClaudeMessage } from "./claudeMessageFormatter";

// CLI entry point - runs when executed directly
const cliOptionsSchema = z.object({
  workspaceDir: z.string(),
  changedFiles: z.array(z.string()),
  prTitle: z.string(),
  prDescription: z.string(),
  baseBranch: z.string(),
  headBranch: z.string(),
  outputDir: z.string(),
  pathToClaudeCodeExecutable: z.string().optional(),
  setupScript: z.string().optional(),
  installCommand: z.string().optional(),
  devCommand: z.string().optional(),
  convexSiteUrl: z.string().optional(),
  auth: z.union([
    z.object({ taskRunJwt: z.string() }),
    z.object({ anthropicApiKey: z.string() }),
  ]),
});

async function main() {
  const optionsJson = process.env.SCREENSHOT_OPTIONS;
  if (!optionsJson) {
    console.error("SCREENSHOT_OPTIONS environment variable is required");
    process.exit(1);
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(optionsJson);
  } catch (error) {
    console.error("Failed to parse SCREENSHOT_OPTIONS as JSON:", error);
    process.exit(1);
  }

  const validated = cliOptionsSchema.safeParse(parsed);
  if (!validated.success) {
    console.error("Invalid SCREENSHOT_OPTIONS:", validated.error.format());
    process.exit(1);
  }

  const options = validated.data;
  const result = await claudeCodeCapturePRScreenshots(options as CaptureScreenshotsOptions);

  // Output result as JSON to stdout
  console.log(JSON.stringify(result));
}

// Check if running as CLI (not imported as module)
// Only run as CLI if SCREENSHOT_OPTIONS env var is set - this is the definitive signal
// that we're being run as a CLI, not imported as a module
const shouldRunAsCli = !!process.env.SCREENSHOT_OPTIONS;

if (shouldRunAsCli) {
  main().catch((error) => {
    console.error("CLI execution failed:", error);
    process.exit(1);
  });
}
