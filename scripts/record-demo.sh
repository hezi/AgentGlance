#!/bin/bash
# Record a demo GIF of AgentGlance by simulating hook events
# Usage: ./scripts/record-demo.sh
#
# Prerequisites:
#   - AgentGlance must be running
#   - ffmpeg must be installed (brew install ffmpeg)
#   - screencapture (built into macOS)

set -e

PORT=7483
BASE_URL="http://localhost:${PORT}/hook"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ASSETS_DIR="${PROJECT_DIR}/assets"
MOV_FILE="${ASSETS_DIR}/demo.mov"
GIF_FILE="${ASSETS_DIR}/demo.gif"
PALETTE_FILE="/tmp/agentglance-palette.png"

mkdir -p "$ASSETS_DIR"

# Check prerequisites
if ! curl -s "http://localhost:${PORT}/health" > /dev/null 2>&1 && \
   ! curl -s -X POST -H 'Content-Type: application/json' \
     -d '{"session_id":"ping","cwd":"/tmp","hook_event_name":"SessionStart"}' \
     "${BASE_URL}/SessionStart" > /dev/null 2>&1; then
    echo "Warning: AgentGlance might not be running on port ${PORT}"
    echo "Start AgentGlance first, then re-run this script."
fi

if ! command -v ffmpeg &> /dev/null; then
    echo "Error: ffmpeg is required. Install with: brew install ffmpeg"
    exit 1
fi

# Helper: send a hook event
send() {
    local event="$1"
    local json="$2"
    curl -s --connect-timeout 2 -X POST \
        -H 'Content-Type: application/json' \
        -d "$json" \
        "${BASE_URL}/${event}" > /dev/null 2>&1 || true
}

# Get screen dimensions for recording region (in logical/point coordinates)
# screencapture -R uses point coordinates, not physical pixels
# Use AppleScript to get the actual desktop bounds in points
SCREEN_WIDTH=$(osascript -e 'tell application "Finder" to get item 3 of (get bounds of window of desktop)' 2>/dev/null)
SCREEN_WIDTH=${SCREEN_WIDTH:-1920}
REGION_W=500
REGION_H=400
REGION_X=$(( (SCREEN_WIDTH - REGION_W) / 2 ))
REGION_Y=0

echo "=== AgentGlance Demo Recorder ==="
echo ""
echo "This will:"
echo "  1. Record the notch area of your screen (${REGION_W}x${REGION_H} at top-center)"
echo "  2. Simulate Claude Code sessions with hook events"
echo "  3. Convert the recording to a GIF at ${GIF_FILE}"
echo ""
echo "Make sure AgentGlance is running and visible."
echo ""
read -p "Press Enter to start recording..."

# Clean up any leftover test sessions
send "SessionEnd" '{"session_id":"demo-1","cwd":"/Users/demo/Projects/MyApp","hook_event_name":"SessionEnd"}'
send "SessionEnd" '{"session_id":"demo-2","cwd":"/Users/demo/Projects/Backend","hook_event_name":"SessionEnd"}'
sleep 1

# Start screen recording in background using ffmpeg
# Capture full screen via avfoundation, crop to the notch region
# Use Retina scale factor to convert point coordinates to pixel coordinates for the crop filter
PIXEL_WIDTH=$(system_profiler SPDisplaysDataType 2>/dev/null | grep Resolution | head -1 | awk '{print $2}')
PIXEL_WIDTH=${PIXEL_WIDTH:-3840}
SCALE=$(( PIXEL_WIDTH / SCREEN_WIDTH ))
CROP_X=$(( REGION_X * SCALE ))
CROP_Y=$(( REGION_Y * SCALE ))
CROP_W=$(( REGION_W * SCALE ))
CROP_H=$(( REGION_H * SCALE ))

echo "Recording started..."
ffmpeg -y -f avfoundation -framerate 30 -capture_cursor 1 -i "Capture screen 0" \
    -vf "crop=${CROP_W}:${CROP_H}:${CROP_X}:${CROP_Y}" \
    -c:v libx264 -preset ultrafast -an "$MOV_FILE" > /dev/null 2>&1 &
RECORD_PID=$!
sleep 2

# --- Demo sequence ---

echo "  Starting sessions..."
send "SessionStart" '{"session_id":"demo-1","cwd":"/Users/demo/Projects/MyApp","hook_event_name":"SessionStart"}'
send "SessionStart" '{"session_id":"demo-2","cwd":"/Users/demo/Projects/Backend","hook_event_name":"SessionStart"}'
sleep 1

echo "  Session 1: working (npm test)..."
send "UserPromptSubmit" '{"session_id":"demo-1","cwd":"/Users/demo/Projects/MyApp","hook_event_name":"UserPromptSubmit"}'
sleep 0.5
send "PreToolUse" '{"session_id":"demo-1","cwd":"/Users/demo/Projects/MyApp","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm test"}}'
sleep 2

echo "  Session 1: permission request (rm -rf node_modules)..."
send "PermissionRequest" '{"session_id":"demo-1","cwd":"/Users/demo/Projects/MyApp","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf node_modules && npm install"}}'
sleep 4

echo "  Session 2: finished..."
send "UserPromptSubmit" '{"session_id":"demo-2","cwd":"/Users/demo/Projects/Backend","hook_event_name":"UserPromptSubmit"}'
sleep 0.5
send "PreToolUse" '{"session_id":"demo-2","cwd":"/Users/demo/Projects/Backend","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/Users/demo/Projects/Backend/src/main.rs"}}'
sleep 1
send "PostToolUse" '{"session_id":"demo-2","cwd":"/Users/demo/Projects/Backend","hook_event_name":"PostToolUse","tool_name":"Edit"}'
send "Stop" '{"session_id":"demo-2","cwd":"/Users/demo/Projects/Backend","hook_event_name":"Stop"}'
sleep 3

echo "  Session 1: plan review..."
send "PreToolUse" '{"session_id":"demo-1","cwd":"/Users/demo/Projects/MyApp","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode"}'
sleep 0.5
send "PermissionRequest" '{"session_id":"demo-1","cwd":"/Users/demo/Projects/MyApp","hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode"}'
sleep 4

echo "  Ending sessions..."
send "SessionEnd" '{"session_id":"demo-1","cwd":"/Users/demo/Projects/MyApp","hook_event_name":"SessionEnd"}'
send "SessionEnd" '{"session_id":"demo-2","cwd":"/Users/demo/Projects/Backend","hook_event_name":"SessionEnd"}'
sleep 2

# Stop recording (ffmpeg needs SIGINT to finalize the file)
echo "Stopping recording..."
kill -INT "$RECORD_PID" 2>/dev/null || true
wait "$RECORD_PID" 2>/dev/null || true
sleep 1

if [ ! -f "$MOV_FILE" ]; then
    echo "Error: Recording file not found at $MOV_FILE"
    echo "screencapture may have been cancelled. Try again."
    exit 1
fi

# Convert to GIF
echo "Converting to GIF..."
# Generate palette for better quality
ffmpeg -y -i "$MOV_FILE" \
    -vf "fps=15,scale=500:-1:flags=lanczos,palettegen=stats_mode=diff" \
    "$PALETTE_FILE" 2>/dev/null

# Create GIF using the palette
ffmpeg -y -i "$MOV_FILE" -i "$PALETTE_FILE" \
    -lavfi "fps=15,scale=500:-1:flags=lanczos [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=3" \
    "$GIF_FILE" 2>/dev/null

# Clean up
rm -f "$MOV_FILE" "$PALETTE_FILE"

if [ -f "$GIF_FILE" ]; then
    SIZE=$(du -h "$GIF_FILE" | awk '{print $1}')
    echo ""
    echo "Done! Demo GIF saved to: $GIF_FILE ($SIZE)"
    echo "Open with: open $GIF_FILE"
else
    echo "Error: Failed to create GIF"
    exit 1
fi
