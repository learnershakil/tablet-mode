#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Tablet Mode: Extend Hyprland desktop to Android tablet
# via Sunshine (Host) + Moonlight (Client) over USB tethering.
#
# GPU Layout (this machine):
#   card0 = NVIDIA RTX 3050 (PRIMARY DRM — Hyprland compositor)
#   card1 = Intel UHD        (SECONDARY — drives eDP-1 via blit)
#   renderD128 = Intel       renderD129 = NVIDIA
#
# Headless outputs are rendered on card0 (NVIDIA primary).
# Sunshine captures via wlr-screencopy and encodes with libx264
# (software) since NVENC has DMABUF scaling issues with wlgrab.
# ═══════════════════════════════════════════════════════════════════

XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export XDG_RUNTIME_DIR

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

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LOG_FILE=${TABLET_LOG_FILE:-"$SCRIPT_DIR/sunshine-tablet.log"}

start_tablet() {
    if ! detect_wayland_display; then
        notify-send "Tablet Mode" "ERROR: Could not detect WAYLAND_DISPLAY"
        exit 1
    fi

    export XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-Hyprland}
    export XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-wayland}

    # Keep things predictable across repeated starts.
    if [ "${TABLET_CLEAN_HEADLESS:-1}" = "1" ]; then
        hyprctl monitors -j | jq -r '.[] | select(.name | startswith("HEADLESS-")) | .name' | while read -r m; do
            hyprctl output remove "$m" >/dev/null 2>&1 || true
        done
    fi

    CURRENT_WS=$(hyprctl activeworkspace -j | jq -r '.id')
    NEXT_WS=$((CURRENT_WS + 1))

    PRIMARY_MONITOR=$(get_primary_monitor)
    if [ -z "$PRIMARY_MONITOR" ]; then
        notify-send "Tablet Mode" "ERROR: Could not detect primary monitor"
        exit 1
    fi

    # ── Create Headless Monitor ──────────────────────────────────
    hyprctl output create headless
    sleep 2
    MONITOR=$(hyprctl monitors -j | jq -r '.[] | select(.name | startswith("HEADLESS-")) | .name' | tail -n 1)

    if [ -z "$MONITOR" ]; then
        notify-send "Tablet Mode" "ERROR: Headless monitor not created"
        exit 1
    fi

    echo "✓ Headless monitor: $MONITOR"

    hyprctl keyword monitor "$MONITOR,1920x1080@60,auto,1"
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
    mkdir -p ~/.config/sunshine
    SUNSHINE_ENCODER=${SUNSHINE_ENCODER:-software}
    SUNSHINE_MIN_LOG_LEVEL=${SUNSHINE_MIN_LOG_LEVEL:-debug}
    SUNSHINE_GPU_MODE=${SUNSHINE_GPU_MODE:-nvidia}

    if [ "$SUNSHINE_GPU_MODE" = "intel" ] || [ "$SUNSHINE_GPU_MODE" = "igpu" ] || [ "$SUNSHINE_GPU_MODE" = "mesa" ]; then
        SUNSHINE_ADAPTER=${SUNSHINE_ADAPTER:-/dev/dri/renderD128}
    else
        SUNSHINE_ADAPTER=${SUNSHINE_ADAPTER:-/dev/dri/renderD129}
    fi

    cat > ~/.config/sunshine/sunshine.conf <<EOF
output_name=${MONITOR}
encoder=${SUNSHINE_ENCODER}
min_log_level=${SUNSHINE_MIN_LOG_LEVEL}
adapter_name=${SUNSHINE_ADAPTER}
EOF
    echo "✓ Sunshine config:"
    cat ~/.config/sunshine/sunshine.conf

    # ── Launch Sunshine ──────────────────────────────────────────
    pkill -x sunshine 2>/dev/null
    sleep 2

    mapfile -t _sunshine_env_kv < <(sunshine_env_for_mode)
    env "${_sunshine_env_kv[@]}" sunshine > "$LOG_FILE" 2>&1 &
    SUNSHINE_PID=$!
    sleep 4

    # ── Verify Encoder ───────────────────────────────────────────
    if grep -q "Found H.264 encoder" "$LOG_FILE" 2>/dev/null; then
        ENCODER=$(grep "Found H.264 encoder" "$LOG_FILE" | tail -1 | sed 's/.*encoder: //')
        echo "✓ Sunshine ready (PID $SUNSHINE_PID, encoder: $ENCODER)"
        echo "✓ Capturing $MONITOR at offset $(grep 'wlgrab.*Offset' "$LOG_FILE" | tail -1 | sed 's/.*Offset: //')"
    else
        echo "⚠ Sunshine started but encoder status unknown"
        tail -5 "$LOG_FILE"
    fi

    notify-send "Tablet Mode" "Started — streaming $MONITOR ($SUNSHINE_GPU_MODE / $SUNSHINE_ENCODER)"
}

stop_tablet() {
    # Close helper windows we spawn for ensuring headless content.
    hyprctl clients -j | jq -r '.[] | select(.class == "tablet-headless") | .address' | while read -r addr; do
        [ -n "$addr" ] || continue
        hyprctl dispatch closewindow "address:$addr" >/dev/null 2>&1 || true
    done

    hyprctl monitors -j | jq -r '.[] | select(.name | startswith("HEADLESS-")) | .name' | while read -r m; do
        hyprctl output remove "$m"
    done
    pkill -x sunshine 2>/dev/null
    brightnessctl s 100%
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
