#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Tablet Mode: Extend Hyprland desktop to Android tablet
# via Sunshine (Host) + Moonlight (Client) over USB tethering.
#
# Current GPU layout on this machine:
#   card0 / renderD129 = NVIDIA RTX 3050
#   card1 / renderD128 = Intel UHD, drives eDP-1
#
# Hyprland 0.56.2 is currently crashing in its headless-output
# screencopy/DMABUF path when Sunshine streams the virtual output.
# Keep Sunshine on the Intel render node by default to avoid hybrid
# NVIDIA import/copy pressure. NVENC can still be selected explicitly.
# ═══════════════════════════════════════════════════════════════════

XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export XDG_RUNTIME_DIR

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LOG_FILE=${TABLET_LOG_FILE:-"$SCRIPT_DIR/sunshine-tablet.log"}
SUNSHINE_CONFIG=${SUNSHINE_CONFIG:-"$HOME/.config/sunshine/sunshine.conf"}

notify_error() {
    notify-send "Tablet Mode" "ERROR: $*" 2>/dev/null || true
}

die() {
    echo "ERROR: $*" >&2
    notify_error "$*"
    exit 1
}

require_cmds() {
    local missing=()
    local cmd
    for cmd in hyprctl jq sunshine; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        die "Missing required command(s): ${missing[*]}"
    fi
}

detect_wayland_display() {
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        return 0
    fi

    local sock
    for sock in "$XDG_RUNTIME_DIR"/wayland-*; do
        if [ -S "$sock" ]; then
            WAYLAND_DISPLAY=$(basename "$sock")
            export WAYLAND_DISPLAY
            return 0
        fi
    done

    return 1
}

get_primary_monitor() {
    hyprctl monitors -j | jq -r '.[] | select(.focused == true) | .name' | head -n 1
}

get_monitor_refresh() {
    local monitor="$1"
    hyprctl monitors -j | jq -r --arg monitor "$monitor" '
        .[] | select(.name == $monitor) | (.refreshRate | round | tostring)
    ' | head -n 1
}

restart_portals() {
    # Ensure systemd user services inherit our current Wayland env.
    # This matters when starting from wofi/rofi or other shells.
    dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE HYPRLAND_INSTANCE_SIGNATURE 2>/dev/null || true
    systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE HYPRLAND_INSTANCE_SIGNATURE 2>/dev/null || true

    systemctl --user restart xdg-desktop-portal xdg-desktop-portal-hyprland
    sleep 3
    echo "✓ Portals restarted"
}

sunshine_env_for_mode() {
    # Prints an env(1) argument list (one per line) to be used like:
    #   mapfile -t env_kv < <(sunshine_env_for_mode)
    #   env "${env_kv[@]}" sunshine ...
    local mode=${SUNSHINE_GPU_MODE:-nvidia}
    local nvidia_json mesa_json

    nvidia_json=$(ls /usr/share/glvnd/egl_vendor.d/*nvidia*.json 2>/dev/null | head -n 1 || true)
    mesa_json=$(ls /usr/share/glvnd/egl_vendor.d/*mesa*.json 2>/dev/null | head -n 1 || true)

    case "$mode" in
        nvidia|dgpu)
            [ -n "$nvidia_json" ] && printf '%s\n' "__EGL_VENDOR_LIBRARY_FILENAMES=$nvidia_json"
            printf '%s\n' "__GLX_VENDOR_LIBRARY_NAME=nvidia"
            printf '%s\n' "LIBVA_DRIVER_NAME=nvidia"
            ;;
        intel|igpu|mesa)
            [ -n "$mesa_json" ] && printf '%s\n' "__EGL_VENDOR_LIBRARY_FILENAMES=$mesa_json"
            printf '%s\n' "__GLX_VENDOR_LIBRARY_NAME=mesa"
            printf '%s\n' "__NV_PRIME_RENDER_OFFLOAD=0"
            printf '%s\n' "__NV_PRIME_RENDER_OFFLOAD_PROVIDER="
            printf '%s\n' "LIBVA_DRIVER_NAME=iHD"
            # On this system DRI_PRIME=0 is invalid; DRI_PRIME=1 yields Intel (iris).
            printf '%s\n' "DRI_PRIME=1"
            printf '%s\n' "MESA_LOADER_DRIVER_OVERRIDE=iris"
            ;;
        *)
            echo "Unknown SUNSHINE_GPU_MODE=$mode (use nvidia|intel)" >&2
            return 2
            ;;
    esac
}

set_sunshine_defaults() {
    local encoder=${SUNSHINE_ENCODER:-vaapi}

    SUNSHINE_ENCODER=${SUNSHINE_ENCODER:-$encoder}
    SUNSHINE_CAPTURE=${SUNSHINE_CAPTURE:-wlr}
    SUNSHINE_MIN_LOG_LEVEL=${SUNSHINE_MIN_LOG_LEVEL:-info}
    SUNSHINE_STREAM_AUDIO=${SUNSHINE_STREAM_AUDIO:-enabled}
    SUNSHINE_CONTROLLER=${SUNSHINE_CONTROLLER:-disabled}

    case "$SUNSHINE_ENCODER" in
        vaapi)
            SUNSHINE_GPU_MODE=${SUNSHINE_GPU_MODE:-intel}
            SUNSHINE_ADAPTER=${SUNSHINE_ADAPTER:-/dev/dri/renderD128}
            ;;
        nvenc)
            SUNSHINE_GPU_MODE=${SUNSHINE_GPU_MODE:-nvidia}
            SUNSHINE_ADAPTER=${SUNSHINE_ADAPTER:-/dev/dri/renderD129}
            ;;
        software)
            SUNSHINE_GPU_MODE=${SUNSHINE_GPU_MODE:-intel}
            SUNSHINE_ADAPTER=${SUNSHINE_ADAPTER:-/dev/dri/renderD128}
            ;;
        *)
            SUNSHINE_GPU_MODE=${SUNSHINE_GPU_MODE:-intel}
            SUNSHINE_ADAPTER=${SUNSHINE_ADAPTER:-/dev/dri/renderD128}
            ;;
    esac
}

cleanup_headless_outputs() {
    hyprctl monitors -j | jq -r '.[] | select(.name | startswith("HEADLESS-")) | .name' | while read -r m; do
        [ -n "$m" ] || continue
        hyprctl output remove "$m" >/dev/null 2>&1 || true
    done
}

write_sunshine_config() {
    local monitor="$1"

    mkdir -p "$(dirname "$SUNSHINE_CONFIG")"
    cat > "$SUNSHINE_CONFIG" <<EOF
output_name=${monitor}
capture=${SUNSHINE_CAPTURE}
encoder=${SUNSHINE_ENCODER}
adapter_name=${SUNSHINE_ADAPTER}
min_log_level=${SUNSHINE_MIN_LOG_LEVEL}
stream_audio=${SUNSHINE_STREAM_AUDIO}
controller=${SUNSHINE_CONTROLLER}
EOF
}

ensure_headless_has_window() {
    local ws="$1"
    local cmd
    cmd=${TABLET_HEADLESS_CMD:-"kitty --class tablet-headless --title Tablet-Headless sh -lc 'echo Tablet Mode headless workspace $ws; exec bash'"}

    hyprctl dispatch exec "[workspace $ws silent] $cmd" >/dev/null 2>&1 || true

    local i
    for i in $(seq 1 15); do
        if hyprctl clients -j | jq -e --argjson ws "$ws" '.[] | select(.workspace.id == $ws) | .address' >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
    done

    return 1
}

start_tablet() {
    require_cmds

    if ! detect_wayland_display; then
        die "Could not detect WAYLAND_DISPLAY"
    fi

    export XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-Hyprland}
    export XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-wayland}

    # Keep things predictable across repeated starts.
    if [ "${TABLET_CLEAN_HEADLESS:-1}" = "1" ]; then
        cleanup_headless_outputs
    fi

    CURRENT_WS=$(hyprctl activeworkspace -j | jq -r '.id')
    NEXT_WS=$((CURRENT_WS + 1))

    PRIMARY_MONITOR=$(get_primary_monitor)
    if [ -z "$PRIMARY_MONITOR" ]; then
        die "Could not detect primary monitor"
    fi

    TABLET_WIDTH=${TABLET_WIDTH:-1920}
    TABLET_HEIGHT=${TABLET_HEIGHT:-1080}
    TABLET_REFRESH=${TABLET_REFRESH:-$(get_monitor_refresh "$PRIMARY_MONITOR")}
    TABLET_REFRESH=${TABLET_REFRESH:-60}

    # ── Create Headless Monitor ──────────────────────────────────
    if ! hyprctl output create headless >/dev/null 2>&1; then
        die "Failed to create Hyprland headless monitor"
    fi

    sleep 2
    MONITOR=$(hyprctl monitors -j | jq -r '.[] | select(.name | startswith("HEADLESS-")) | .name' | tail -n 1)

    if [ -z "$MONITOR" ]; then
        die "Headless monitor not created"
    fi

    echo "✓ Headless monitor: $MONITOR"

    hyprctl keyword monitor "$MONITOR,${TABLET_WIDTH}x${TABLET_HEIGHT}@${TABLET_REFRESH},auto,1"
    brightnessctl s 30% 2>/dev/null || true

    # ── Move Workspace ───────────────────────────────────────────
    hyprctl dispatch moveworkspacetomonitor "$NEXT_WS" "$MONITOR" >/dev/null 2>&1 || true
    hyprctl dispatch focusmonitor "$MONITOR"
    hyprctl dispatch workspace "$NEXT_WS"

    if ensure_headless_has_window "$NEXT_WS"; then
        echo "✓ Headless workspace $NEXT_WS has content"
    else
        echo "⚠ Headless workspace $NEXT_WS appears empty; stream may be black"
    fi

    hyprctl dispatch focusmonitor "$PRIMARY_MONITOR"
    hyprctl dispatch workspace "$CURRENT_WS"

    # ── Restart Portals ──────────────────────────────────────────
    # Must restart so they re-enumerate outputs and expose the
    # headless monitor for wlr-screencopy capture.
    restart_portals

    # ── Write Sunshine Config ────────────────────────────────────
    # output_name must match the Hyprland output name exactly.
    # Sunshine's wlgrab shows "Selected monitor []" for headless
    # (empty description) but correctly uses the offset (1920x0).
    set_sunshine_defaults
    write_sunshine_config "$MONITOR"
    echo "✓ Sunshine config:"
    cat "$SUNSHINE_CONFIG"

    # ── Launch Sunshine ──────────────────────────────────────────
    pkill -x sunshine 2>/dev/null
    sleep 2

    mapfile -t _sunshine_env_kv < <(sunshine_env_for_mode)
    : > "$LOG_FILE"
    env "${_sunshine_env_kv[@]}" sunshine "$SUNSHINE_CONFIG" > "$LOG_FILE" 2>&1 &
    SUNSHINE_PID=$!
    sleep 4

    if ! kill -0 "$SUNSHINE_PID" 2>/dev/null; then
        tail -40 "$LOG_FILE" >&2 || true
        cleanup_headless_outputs
        die "Sunshine exited during startup"
    fi

    # ── Verify Encoder ───────────────────────────────────────────
    if grep -Eq "Found H\\.264 encoder|Found HEVC encoder" "$LOG_FILE" 2>/dev/null; then
        ENCODER=$(grep -E "Found H\\.264 encoder|Found HEVC encoder" "$LOG_FILE" | tail -1 | sed 's/.*encoder: //')
        echo "✓ Sunshine ready (PID $SUNSHINE_PID, encoder: $ENCODER)"
        echo "✓ Capturing $MONITOR at offset $(grep 'wlgrab.*Offset' "$LOG_FILE" | tail -1 | sed 's/.*Offset: //')"
    else
        echo "⚠ Sunshine started but encoder status unknown"
        tail -20 "$LOG_FILE"
    fi

    notify-send "Tablet Mode" "Started — streaming $MONITOR (${TABLET_WIDTH}x${TABLET_HEIGHT}@${TABLET_REFRESH}, $SUNSHINE_GPU_MODE / $SUNSHINE_ENCODER)"
}

stop_tablet() {
    pkill -x sunshine 2>/dev/null
    sleep 1

    # Close helper windows we spawn for ensuring headless content.
    hyprctl clients -j | jq -r '.[] | select(.class == "tablet-headless") | .address' | while read -r addr; do
        [ -n "$addr" ] || continue
        hyprctl dispatch closewindow "address:$addr" >/dev/null 2>&1 || true
    done

    cleanup_headless_outputs
    brightnessctl s 100% 2>/dev/null || true
    notify-send "Tablet Mode" "Stopped"
}

swap_screens() {
    HEADLESS=$(hyprctl monitors -j | jq -r '.[] | select(.name | startswith("HEADLESS-")) | .name' | head -n 1)
    PRIMARY_MONITOR=$(get_primary_monitor)
    if [ -n "$HEADLESS" ] && [ -n "$PRIMARY_MONITOR" ]; then
        hyprctl dispatch swapactiveworkspaces "$PRIMARY_MONITOR" "$HEADLESS"
    fi
}

rotate_screen() {
    MONITOR=$(hyprctl monitors -j | jq -r '.[] | select(.name | startswith("HEADLESS-")) | .name' | head -n 1)
    TRANSFORM=$(hyprctl monitors -j | jq -r ".[] | select(.name == \"$MONITOR\") | .transform")
    if [ "$TRANSFORM" = "0" ]; then
        hyprctl keyword monitor "$MONITOR,1080x2400@60,auto,1,transform,1"
    else
        hyprctl keyword monitor "$MONITOR,2400x1080@60,auto,1,transform,0"
    fi
}

audio_toggle() {
    CURRENT_SINK=$(wpctl status | grep -A 10 "Sinks" | grep "*" | awk '{print $3}' | tr -d '.:')
    SUNSHINE_SINK=$(wpctl status | grep "Sunshine\|sink-sunshine" | awk '{print $2}' | tr -d '.:' | head -n 1)

    if [ -z "$SUNSHINE_SINK" ]; then
        notify-send "Audio" "No Sunshine sink found"
        return 1
    fi

    if [ "$CURRENT_SINK" == "$SUNSHINE_SINK" ]; then
        wpctl set-default @DEFAULT_AUDIO_SINK@
        notify-send "Audio" "Routed to Laptop"
    else
        wpctl set-default "$SUNSHINE_SINK"
        notify-send "Audio" "Routed to Tablet"
    fi
}

status_check() {
    echo "=== Tablet Mode Status ==="
    HEADLESS=$(hyprctl monitors -j | jq -r '.[] | select(.name | startswith("HEADLESS-")) | .name' | head -n 1)
    if [ -n "$HEADLESS" ]; then
        echo "✓ Headless monitor: $HEADLESS"
        hyprctl monitors -j | jq -r --arg monitor "$HEADLESS" '.[] | select(.name == $monitor) | "  \(.width)x\(.height)@\(.refreshRate) workspace \(.activeWorkspace.id)"'
    else
        echo "✗ No headless monitor"
    fi
    if pgrep -x sunshine > /dev/null; then
        echo "✓ Sunshine running (PID $(pgrep -x sunshine))"
        if [ -f "$LOG_FILE" ]; then
            LAST_LATENCY=$(grep "Network:" "$LOG_FILE" | tail -1)
            [ -n "$LAST_LATENCY" ] && echo "  $LAST_LATENCY"
            LAST_ERROR=$(grep -i "error" "$LOG_FILE" | grep -v "ignore\|safely\|Failed to create client" | tail -1)
            [ -n "$LAST_ERROR" ] && echo "  ⚠ $LAST_ERROR"
        fi
    else
        echo "✗ Sunshine not running"
    fi
}

show_menu() {
    CHOICE=$(echo -e "Start\nStop\nSwap Workspaces\nRotate\nToggle Audio\nStatus" | wofi --dmenu --prompt "Tablet Mode")
    case "$CHOICE" in
        "Start") start_tablet ;;
        "Stop") stop_tablet ;;
        "Swap Workspaces") swap_screens ;;
        "Rotate") rotate_screen ;;
        "Toggle Audio") audio_toggle ;;
        "Status") status_check ;;
    esac
}

case "$1" in
    start) start_tablet ;;
    stop) stop_tablet ;;
    swap) swap_screens ;;
    rotate) rotate_screen ;;
    audio) audio_toggle ;;
    status) status_check ;;
    menu) show_menu ;;
    *) echo "Usage: $0 {start|stop|swap|rotate|audio|status|menu}" ;;
esac
