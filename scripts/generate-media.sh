#!/bin/bash
set -euo pipefail

# generate-media.sh — Automated screenshot & GIF generator for AgentGlance
#
# Usage:
#   ./scripts/generate-media.sh                  # auto-expand mode (no cursor)
#   ./scripts/generate-media.sh --with-cursor     # mouse simulation (requires cliclick)
#   ./scripts/generate-media.sh --scenario approval  # run one scenario only
#   ./scripts/generate-media.sh --list            # list available scenarios
#
# Prerequisites:
#   - AgentGlance must be running (or will be launched)
#   - ffmpeg (brew install ffmpeg)
#   - cliclick (brew install cliclick) — only for --with-cursor mode

PORT=7483
BASE_URL="http://localhost:$PORT/hook"
OUTPUT_DIR="assets/media"
TMP_DIR="/tmp/agentglance-media"
WITH_CURSOR=false
SINGLE_SCENARIO=""
GIF_FPS=15
GIF_WIDTH=600

# Test session IDs (must match AppState.TestSession)
SID_CLAUDE="test-claude"
SID_CODEX="test-codex"
SID_GEMINI="test-gemini"
CWD_CLAUDE="/Users/demo/Projects/MyApp"
CWD_CODEX="/Users/demo/Projects/Backend"
CWD_GEMINI="/Users/demo/Projects/Frontend"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[media]${NC} $1"; }
warn()  { echo -e "${YELLOW}[media]${NC} $1"; }
error() { echo -e "${RED}[media]${NC} $1" >&2; exit 1; }

# ─── Parse args ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --with-cursor) WITH_CURSOR=true; shift ;;
        --scenario) SINGLE_SCENARIO="$2"; shift 2 ;;
        --list)
            echo "Available scenarios:"
            echo "  idle          Collapsed pill, no sessions"
            echo "  working       Green spinner, tool running"
            echo "  approval      Yellow approval card"
            echo "  question      AskUserQuestion with options"
            echo "  plan-review   Plan review with markdown"
            echo "  multi-session Three sessions in different states"
            echo "  keyboard-arrows  Arrow keys keyboard navigation"
            echo "  keyboard-numbers Number keys keyboard navigation"
            echo "  demo          Full feature walkthrough (hero GIF)"
            exit 0 ;;
        *) error "Unknown argument: $1" ;;
    esac
done

# ─── Prerequisites ───────────────────────────────────────────────────────

if ! command -v ffmpeg &>/dev/null; then
    error "ffmpeg is required. Install with: brew install ffmpeg"
fi

if $WITH_CURSOR && ! command -v cliclick &>/dev/null; then
    error "cliclick is required for --with-cursor mode. Install with: brew install cliclick"
fi

mkdir -p "$OUTPUT_DIR" "$TMP_DIR"

# ─── Helpers ─────────────────────────────────────────────────────────────

send() {
    local event="$1"
    local json="$2"
    # PermissionRequest holds the connection open — run in background with timeout
    if [ "$event" = "PermissionRequest" ]; then
        curl -s --max-time 30 --connect-timeout 2 -X POST \
            -H 'Content-Type: application/json' \
            -d "$json" \
            "${BASE_URL}/${event}" > /dev/null 2>&1 &
    else
        curl -s --connect-timeout 2 -X POST \
            -H 'Content-Type: application/json' \
            -d "$json" \
            "${BASE_URL}/${event}" > /dev/null 2>&1 || true
    fi
}

wait_server() {
    info "Waiting for AgentGlance server on port $PORT..."
    for i in $(seq 1 30); do
        if curl -s --connect-timeout 1 -X POST \
            -H 'Content-Type: application/json' \
            -d '{"session_id":"ping","cwd":"/tmp","hook_event_name":"SessionStart"}' \
            "${BASE_URL}/SessionStart" > /dev/null 2>&1; then
            # Clean up ping session
            send "SessionEnd" '{"session_id":"ping","cwd":"/tmp","hook_event_name":"SessionEnd"}'
            info "Server ready."
            return
        fi
        sleep 1
    done
    error "Server not responding after 30 seconds. Is AgentGlance running?"
}

clear_sessions() {
    for sid in "$SID_CLAUDE" "$SID_CODEX" "$SID_GEMINI"; do
        send "SessionEnd" "{\"session_id\":\"$sid\",\"cwd\":\"/tmp\",\"hook_event_name\":\"SessionEnd\"}"
    done
    sleep 0.5
}

# Get screen metrics
get_screen_info() {
    SCREEN_WIDTH=$(osascript -e 'tell application "Finder" to get item 3 of (get bounds of window of desktop)' 2>/dev/null || echo 1920)
    SCREEN_HEIGHT=$(osascript -e 'tell application "Finder" to get item 4 of (get bounds of window of desktop)' 2>/dev/null || echo 1080)

    # Detect Retina scale
    PIXEL_WIDTH=$(system_profiler SPDisplaysDataType 2>/dev/null | grep "Resolution" | head -1 | awk '{print $2}' || echo "$SCREEN_WIDTH")
    if [ "$SCREEN_WIDTH" -gt 0 ]; then
        RETINA_SCALE=$((PIXEL_WIDTH / SCREEN_WIDTH))
    else
        RETINA_SCALE=2
    fi
    [ "$RETINA_SCALE" -lt 1 ] && RETINA_SCALE=1

    # Overlay region (centered, top of screen)
    REGION_W=500
    REGION_H=450
    REGION_X=$(( (SCREEN_WIDTH - REGION_W) / 2 ))
    REGION_Y=0

    # Pixel coords for ffmpeg crop
    CROP_W=$((REGION_W * RETINA_SCALE))
    CROP_H=$((REGION_H * RETINA_SCALE))
    CROP_X=$((REGION_X * RETINA_SCALE))
    CROP_Y=0

    # Initial pill position check
    get_pill_center
    info "Pill center: ($PILL_X, $PILL_Y)"
}

screenshot() {
    local name="$1"
    local max_height="${2:-300}"  # optional max height, default 300
    local path="$OUTPUT_DIR/$name"

    # Query the actual window position and capture just the top portion
    local win_info
    win_info=$(osascript -e '
        tell application "System Events"
            set agentProc to first process whose name is "AgentGlance"
            set w to first window of agentProc
            set {x, y} to position of w
            set {width, height} to size of w
            return (x as text) & " " & (y as text) & " " & (width as text) & " " & (height as text)
        end tell
    ' 2>/dev/null || echo "")

    if [ -n "$win_info" ]; then
        local wx wy ww wh h
        wx=$(echo "$win_info" | awk '{print $1}')
        wy=$(echo "$win_info" | awk '{print $2}')
        ww=$(echo "$win_info" | awk '{print $3}')
        wh=$(echo "$win_info" | awk '{print $4}')
        # Cap height to max_height or window height, whichever is smaller
        h=$((wh < max_height ? wh : max_height))
        screencapture -x -R "${wx},${wy},${ww},${h}" "$path" 2>/dev/null
        info "  Screenshot: $name (${ww}x${h} at ${wx},${wy})"
    else
        screencapture -x -R "${REGION_X},${REGION_Y},${REGION_W},${REGION_H}" "$path" 2>/dev/null
        info "  Screenshot: $name (fallback region)"
    fi
}

FFMPEG_PID=""
RECORD_FILE=""
RECORD_COUNT=0

start_record() {
    local max_height="${1:-400}"  # optional max height in points, default 400

    # Kill any lingering ffmpeg first
    pkill -f "ffmpeg.*avfoundation" 2>/dev/null || true
    sleep 0.3

    RECORD_COUNT=$((RECORD_COUNT + 1))
    RECORD_FILE="$TMP_DIR/recording_${RECORD_COUNT}.mov"
    rm -f "$RECORD_FILE"

    # Query live window position for crop (same as screenshot)
    local info crop_x crop_y crop_w crop_h
    info=$(osascript -e '
        tell application "System Events"
            set agentProc to first process whose name is "AgentGlance"
            set w to first window of agentProc
            set {x, y} to position of w
            set {width, height} to size of w
            return (x as text) & " " & (y as text) & " " & (width as text) & " " & (height as text)
        end tell
    ' 2>/dev/null || echo "")

    if [ -n "$info" ]; then
        local wx wy ww wh h
        wx=$(echo "$info" | awk '{print $1}')
        wy=$(echo "$info" | awk '{print $2}')
        ww=$(echo "$info" | awk '{print $3}')
        wh=$(echo "$info" | awk '{print $4}')
        h=$((wh < max_height ? wh : max_height))
        crop_x=$(( wx * RETINA_SCALE ))
        crop_y=$(( wy * RETINA_SCALE ))
        crop_w=$(( ww * RETINA_SCALE ))
        crop_h=$(( h * RETINA_SCALE ))
    else
        crop_x=$CROP_X; crop_y=$CROP_Y; crop_w=$CROP_W; crop_h=$CROP_H
    fi

    ffmpeg -y -f avfoundation -framerate 30 -capture_cursor 1 \
        -i "Capture screen 0" \
        -vf "crop=${crop_w}:${crop_h}:${crop_x}:${crop_y}" \
        -c:v libx264 -preset ultrafast -crf 18 \
        "$RECORD_FILE" \
        </dev/null > /dev/null 2>&1 &
    FFMPEG_PID=$!
    sleep 1.5  # let ffmpeg start and stabilize
}

stop_record() {
    local gif_name="$1"
    local gif_path="$OUTPUT_DIR/$gif_name"
    local palette="$TMP_DIR/palette_${RECORD_COUNT}.png"

    # Stop ffmpeg gracefully
    if [ -n "$FFMPEG_PID" ] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
        kill -INT "$FFMPEG_PID" 2>/dev/null || true
        # Wait up to 5 seconds for it to finish
        for i in $(seq 1 10); do
            kill -0 "$FFMPEG_PID" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "$FFMPEG_PID" 2>/dev/null || true
    fi
    FFMPEG_PID=""

    sleep 0.5

    if [ ! -f "$RECORD_FILE" ] || [ ! -s "$RECORD_FILE" ]; then
        warn "  No recording file found, skipping GIF: $gif_name"
        return
    fi

    # Two-pass GIF conversion
    ffmpeg -y -i "$RECORD_FILE" \
        -vf "fps=${GIF_FPS},scale=${GIF_WIDTH}:-1:flags=lanczos,palettegen=stats_mode=diff" \
        "$palette" </dev/null 2>/dev/null

    ffmpeg -y -i "$RECORD_FILE" -i "$palette" \
        -lavfi "fps=${GIF_FPS},scale=${GIF_WIDTH}:-1:flags=lanczos [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=3" \
        "$gif_path" </dev/null 2>/dev/null

    rm -f "$RECORD_FILE" "$palette"

    local size
    size=$(du -h "$gif_path" | awk '{print $1}')
    info "  GIF: $gif_name ($size)"
}

# Query the live window position and return pill center
get_pill_center() {
    local info
    info=$(osascript -e '
        tell application "System Events"
            set agentProc to first process whose name is "AgentGlance"
            set w to first window of agentProc
            set {x, y} to position of w
            set {width, height} to size of w
            return (x as text) & " " & (y as text) & " " & (width as text) & " " & (height as text)
        end tell
    ' 2>/dev/null || echo "")

    if [ -n "$info" ]; then
        local wx wy ww wh
        wx=$(echo "$info" | awk '{print $1}')
        wy=$(echo "$info" | awk '{print $2}')
        ww=$(echo "$info" | awk '{print $3}')
        wh=$(echo "$info" | awk '{print $4}')
        PILL_X=$(( wx + ww / 2 ))
        PILL_Y=$(( wy + 15 ))
    else
        PILL_X=$((SCREEN_WIDTH / 2))
        PILL_Y=40
    fi
}

expand_overlay() {
    get_pill_center
    # Move mouse smoothly to pill center, hold there for hover detection
    osascript -e "
        tell application \"System Events\"
            -- Move in steps for smooth cursor animation
            set startX to 0
            set startY to $((SCREEN_HEIGHT / 2))
            set endX to $PILL_X
            set endY to $PILL_Y
            set steps to 15
            repeat with i from 1 to steps
                set curX to startX + (endX - startX) * i / steps
                set curY to startY + (endY - startY) * i / steps
                do shell script \"cliclick m:\" & (curX as integer) & \",\" & (curY as integer)
                delay 0.02
            end repeat
        end tell
    " 2>/dev/null
    # Hold position to trigger hover
    sleep 0.3
    cliclick m:"$PILL_X","$PILL_Y"
    sleep 1.5
}

collapse_overlay() {
    get_pill_center
    # Smooth mouse exit
    osascript -e "
        tell application \"System Events\"
            set startX to $PILL_X
            set startY to $PILL_Y
            set endX to 0
            set endY to $((SCREEN_HEIGHT / 2))
            set steps to 10
            repeat with i from 1 to steps
                set curX to startX + (endX - startX) * i / steps
                set curY to startY + (endY - startY) * i / steps
                do shell script \"cliclick m:\" & (curX as integer) & \",\" & (curY as integer)
                delay 0.02
            end repeat
        end tell
    " 2>/dev/null
    sleep 0.5
}

press_key() {
    cliclick "kp:$1"
    sleep 0.3
}

press_keys() {
    for key in "$@"; do
        cliclick "kp:$key"
        sleep 0.5
    done
}

hotkey() {
    # Cmd+Shift+C — use kd/ku for modifiers, t: to type the key
    cliclick kd:cmd,shift t:c ku:cmd,shift
    sleep 0.8
}

# ─── Scenarios ───────────────────────────────────────────────────────────

scenario_idle() {
    info "Scenario: idle"
    clear_sessions
    sleep 1
    screenshot "idle.png" 60
}

scenario_working() {
    info "Scenario: working"
    clear_sessions
    sleep 0.3

    send "SessionStart" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"SessionStart\"}"
    send "UserPromptSubmit" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"UserPromptSubmit\"}"
    send "PreToolUse" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm run build && npm test\"}}"
    sleep 1

    start_record 200

    # Show collapsed pill with spinner for 2s
    sleep 2

    # Hover to expand
    expand_overlay
    sleep 2

    screenshot "working.png" 200

    collapse_overlay
    sleep 1

    stop_record "working.gif"
    clear_sessions
}

scenario_approval() {
    info "Scenario: approval"
    clear_sessions
    sleep 0.3

    send "SessionStart" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"SessionStart\"}"
    send "UserPromptSubmit" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"UserPromptSubmit\"}"
    send "PreToolUse" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf node_modules && npm install\"}}"
    sleep 0.3
    send "PermissionRequest" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf node_modules && npm install\"}}"
    sleep 1

    start_record 400

    # Hover to expand and show the approval card
    expand_overlay
    sleep 3

    screenshot "approval.png" 400

    # Show for a moment then use keyboard to Allow
    sleep 1
    hotkey
    sleep 0.5
    press_keys arrow-right return  # select Allow and execute
    sleep 1

    stop_record "approval.gif"
    clear_sessions
}

scenario_question() {
    info "Scenario: question"
    clear_sessions
    sleep 0.3

    local tool_input='{"questions":[{"question":"Which database should we use?","header":"Database","options":[{"label":"PostgreSQL","description":"Relational, battle-tested"},{"label":"SQLite","description":"Embedded, zero config"},{"label":"MongoDB","description":"Document store"},{"label":"Redis","description":"In-memory, fast"}],"multiSelect":false}],"answers":{}}'

    send "SessionStart" "{\"session_id\":\"$SID_CODEX\",\"cwd\":\"$CWD_CODEX\",\"hook_event_name\":\"SessionStart\"}"
    send "PreToolUse" "{\"session_id\":\"$SID_CODEX\",\"cwd\":\"$CWD_CODEX\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":$tool_input}"
    sleep 0.3
    send "PermissionRequest" "{\"session_id\":\"$SID_CODEX\",\"cwd\":\"$CWD_CODEX\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":$tool_input}"
    sleep 1

    start_record 400

    # Hover to expand and show question
    expand_overlay
    sleep 2

    screenshot "question.png" 400

    # Use keyboard nav to select an answer
    hotkey
    sleep 0.5
    # Navigate to first option (PostgreSQL) and select it
    press_keys arrow-right return
    sleep 1

    stop_record "question.gif"
    clear_sessions
}

scenario_plan_review() {
    info "Scenario: plan-review"
    clear_sessions
    sleep 0.3

    send "SessionStart" "{\"session_id\":\"$SID_GEMINI\",\"cwd\":\"$CWD_GEMINI\",\"hook_event_name\":\"SessionStart\"}"
    send "PreToolUse" "{\"session_id\":\"$SID_GEMINI\",\"cwd\":\"$CWD_GEMINI\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"ExitPlanMode\"}"
    sleep 0.3
    send "PermissionRequest" "{\"session_id\":\"$SID_GEMINI\",\"cwd\":\"$CWD_GEMINI\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"ExitPlanMode\"}"
    sleep 1

    start_record 400

    # Hover to expand and show plan card
    expand_overlay
    sleep 2

    screenshot "plan-review.png" 400

    # Approve via keyboard
    hotkey
    sleep 0.5
    press_keys arrow-right return  # Approve
    sleep 1

    stop_record "plan-review.gif"
    clear_sessions
}

scenario_multi_session() {
    info "Scenario: multi-session"
    clear_sessions
    sleep 0.3

    # Session 1: working (green)
    send "SessionStart" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"SessionStart\"}"
    send "UserPromptSubmit" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"UserPromptSubmit\"}"
    send "PreToolUse" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/Users/demo/Projects/MyApp/src/App.swift\"}}"

    # Session 2: awaiting approval (yellow)
    send "SessionStart" "{\"session_id\":\"$SID_CODEX\",\"cwd\":\"$CWD_CODEX\",\"hook_event_name\":\"SessionStart\"}"
    send "PreToolUse" "{\"session_id\":\"$SID_CODEX\",\"cwd\":\"$CWD_CODEX\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test\"}}"
    send "PermissionRequest" "{\"session_id\":\"$SID_CODEX\",\"cwd\":\"$CWD_CODEX\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test\"}}"

    # Session 3: ready (red)
    send "SessionStart" "{\"session_id\":\"$SID_GEMINI\",\"cwd\":\"$CWD_GEMINI\",\"hook_event_name\":\"SessionStart\"}"
    send "UserPromptSubmit" "{\"session_id\":\"$SID_GEMINI\",\"cwd\":\"$CWD_GEMINI\",\"hook_event_name\":\"UserPromptSubmit\"}"
    send "PreToolUse" "{\"session_id\":\"$SID_GEMINI\",\"cwd\":\"$CWD_GEMINI\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/Users/demo/Projects/Frontend/README.md\"}}"
    send "Stop" "{\"session_id\":\"$SID_GEMINI\",\"cwd\":\"$CWD_GEMINI\",\"hook_event_name\":\"Stop\"}"

    sleep 1

    start_record 450

    # Hover to expand showing all 3 sessions
    expand_overlay
    sleep 2

    screenshot "multi-session.png" 450

    # Use keyboard nav to cycle through sessions
    hotkey
    sleep 0.5
    press_keys arrow-down arrow-down arrow-up
    sleep 1

    collapse_overlay
    sleep 0.5

    stop_record "multi-session.gif"
    clear_sessions
}

scenario_keyboard_arrows() {
    info "Scenario: keyboard-nav-arrows"
    clear_sessions
    sleep 0.3

    # Ensure arrows mode
    defaults write app.agentglance.AgentGlance keyboardNavMode arrows 2>/dev/null || true

    # Create sessions: one working, one with approval
    send "SessionStart" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"SessionStart\"}"
    send "UserPromptSubmit" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"UserPromptSubmit\"}"
    send "PreToolUse" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test\"}}"

    send "SessionStart" "{\"session_id\":\"$SID_CODEX\",\"cwd\":\"$CWD_CODEX\",\"hook_event_name\":\"SessionStart\"}"
    send "PreToolUse" "{\"session_id\":\"$SID_CODEX\",\"cwd\":\"$CWD_CODEX\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf dist\"}}"
    send "PermissionRequest" "{\"session_id\":\"$SID_CODEX\",\"cwd\":\"$CWD_CODEX\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf dist\"}}"
    sleep 1

    start_record 400

    # Hotkey opens overlay with focus on first row
    hotkey
    sleep 1

    # Navigate down to approval row
    press_key arrow-down
    sleep 0.8

    # Show actions bar
    press_key arrow-right
    sleep 0.5
    press_key arrow-right  # move to "Always"
    sleep 0.5
    press_key arrow-right  # move to "Deny"
    sleep 0.8

    screenshot "keyboard-arrows.png" 400

    # Go back to Allow and execute
    press_key arrow-left
    sleep 0.3
    press_key arrow-left
    sleep 0.3
    press_key return  # Allow → overlay collapses
    sleep 1.5

    stop_record "keyboard-arrows.gif"
    clear_sessions
}

scenario_keyboard_numbers() {
    info "Scenario: keyboard-nav-numbers"
    clear_sessions
    sleep 0.3

    # Switch to numbers mode
    defaults write app.agentglance.AgentGlance keyboardNavMode numbers 2>/dev/null || true

    # Create sessions: one working, one with approval
    send "SessionStart" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"SessionStart\"}"
    send "UserPromptSubmit" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"UserPromptSubmit\"}"
    send "PreToolUse" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test\"}}"

    send "SessionStart" "{\"session_id\":\"$SID_CODEX\",\"cwd\":\"$CWD_CODEX\",\"hook_event_name\":\"SessionStart\"}"
    send "PreToolUse" "{\"session_id\":\"$SID_CODEX\",\"cwd\":\"$CWD_CODEX\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf dist\"}}"
    send "PermissionRequest" "{\"session_id\":\"$SID_CODEX\",\"cwd\":\"$CWD_CODEX\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf dist\"}}"
    sleep 1

    start_record 400

    # Hotkey opens overlay with number badges visible
    hotkey
    sleep 1.5

    screenshot "keyboard-numbers.png" 400

    # Press 2 to select the approval row → action badges appear
    cliclick t:2
    sleep 1.5

    # Press 1 to Allow → overlay collapses
    cliclick t:1
    sleep 1.5

    stop_record "keyboard-numbers.gif"

    # Restore arrows mode
    defaults write app.agentglance.AgentGlance keyboardNavMode arrows 2>/dev/null || true
    clear_sessions
}

scenario_demo() {
    info "Scenario: demo (full feature walkthrough)"
    clear_sessions
    sleep 0.5

    start_record 450

    # Phase 1: Session starts, working — show collapsed spinner
    send "SessionStart" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"SessionStart\"}"
    send "UserPromptSubmit" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"UserPromptSubmit\"}"
    send "PreToolUse" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm run build\"}}"
    sleep 2

    # Hover to show expanded working state
    expand_overlay
    sleep 1.5

    # Phase 2: Approval appears on second session
    send "SessionStart" "{\"session_id\":\"$SID_CODEX\",\"cwd\":\"$CWD_CODEX\",\"hook_event_name\":\"SessionStart\"}"
    send "PreToolUse" "{\"session_id\":\"$SID_CODEX\",\"cwd\":\"$CWD_CODEX\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf dist && npm install\"}}"
    send "PermissionRequest" "{\"session_id\":\"$SID_CODEX\",\"cwd\":\"$CWD_CODEX\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf dist && npm install\"}}"
    sleep 2

    # Use keyboard to Allow the approval
    hotkey
    sleep 0.5
    press_keys arrow-right return
    sleep 1

    # Phase 3: Question appears
    local q_input='{"questions":[{"question":"Which framework?","header":"Framework","options":[{"label":"React"},{"label":"Vue"},{"label":"Svelte"}],"multiSelect":false}],"answers":{}}'
    send "SessionStart" "{\"session_id\":\"$SID_GEMINI\",\"cwd\":\"$CWD_GEMINI\",\"hook_event_name\":\"SessionStart\"}"
    send "PermissionRequest" "{\"session_id\":\"$SID_GEMINI\",\"cwd\":\"$CWD_GEMINI\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":$q_input}"
    sleep 1

    # Hover to show question
    expand_overlay
    sleep 2

    # Answer via keyboard
    hotkey
    sleep 0.5
    press_keys arrow-right return  # select React
    sleep 1

    # Phase 4: First session finishes
    send "Stop" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"Stop\"}"
    sleep 1.5

    # End all
    send "SessionEnd" "{\"session_id\":\"$SID_CLAUDE\",\"cwd\":\"$CWD_CLAUDE\",\"hook_event_name\":\"SessionEnd\"}"
    send "SessionEnd" "{\"session_id\":\"$SID_CODEX\",\"cwd\":\"$CWD_CODEX\",\"hook_event_name\":\"SessionEnd\"}"
    send "SessionEnd" "{\"session_id\":\"$SID_GEMINI\",\"cwd\":\"$CWD_GEMINI\",\"hook_event_name\":\"SessionEnd\"}"
    sleep 1.5

    stop_record "demo.gif"

    # Copy hero GIF
    cp "$OUTPUT_DIR/demo.gif" assets/demo.gif 2>/dev/null || true
    cp "$OUTPUT_DIR/demo.gif" docs/demo.gif 2>/dev/null || true
    info "  Copied demo.gif to assets/ and docs/"
}

# ─── Main ────────────────────────────────────────────────────────────────

info "=== AgentGlance Media Generator ==="
info "Mode: $(if $WITH_CURSOR; then echo 'cursor simulation'; else echo 'auto-expand'; fi)"

wait_server
get_screen_info
info "Screen: ${SCREEN_WIDTH}x${SCREEN_HEIGHT} @ ${RETINA_SCALE}x"
info "Capture region: ${REGION_W}x${REGION_H} at (${REGION_X}, ${REGION_Y})"
info "Output: $OUTPUT_DIR"
echo ""

ALL_SCENARIOS=(idle working approval question plan-review multi-session keyboard-arrows keyboard-numbers demo)

if [ -n "$SINGLE_SCENARIO" ]; then
    case "$SINGLE_SCENARIO" in
        idle) scenario_idle ;;
        working) scenario_working ;;
        approval) scenario_approval ;;
        question) scenario_question ;;
        plan-review) scenario_plan_review ;;
        multi-session) scenario_multi_session ;;
        keyboard-arrows) scenario_keyboard_arrows ;;
        keyboard-numbers) scenario_keyboard_numbers ;;
        demo) scenario_demo ;;
        *) error "Unknown scenario: $SINGLE_SCENARIO. Use --list to see available scenarios." ;;
    esac
else
    for s in "${ALL_SCENARIOS[@]}"; do
        "scenario_${s//-/_}"
        sleep 1
    done
fi

# Cleanup
rm -rf "$TMP_DIR"

echo ""
info "=== Done! ==="
info "Output files:"
ls -lh "$OUTPUT_DIR"/*.{png,gif} 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'
