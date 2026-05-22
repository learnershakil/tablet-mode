# Tablet Mode (Hyprland → Sunshine → Moonlight)

Stream a dedicated **Hyprland headless output** to an Android tablet using **Sunshine** (host) and **Moonlight** (client). This repo provides a single script, `tablet.sh`, that creates a headless “monitor”, ensures it has visible content, restarts portals so capture can see the new output, and starts Sunshine with sensible defaults.

**Tested on (this machine)**

- Arch Linux
- Hyprland `0.55.1`
- Sunshine `2026.516.143833`
- Hybrid GPU: Intel iGPU + NVIDIA dGPU
  - Render nodes are system-specific; on this machine: Intel `/dev/dri/renderD128`, NVIDIA `/dev/dri/renderD129`

## What this solves

On Wayland/Hyprland, it’s common to see a “black screen” in Moonlight even when input works. In practice this is usually one of:

- The headless workspace is **empty** (nothing to render → nothing to capture).
- Sunshine’s Wayland capture path is **DMA-BUF only** on many builds; GPU/driver/modifier mismatches can lead to **import failures / black frames**.

`tablet.sh` addresses the first issue by always placing a window on the headless workspace, and gives you a simple switch (`SUNSHINE_GPU_MODE`) to experiment with GPU binding for the second.

## Files

- `tablet.sh` — main entrypoint.
- `sunshine-tablet.log` — runtime Sunshine log written next to the script (generated; ignored by git).

## How it works (high level)

When you run `./tablet.sh start`, it:

1. Detects the active `WAYLAND_DISPLAY` socket from `$XDG_RUNTIME_DIR/wayland-*` (no hardcoding).
2. Optionally removes any existing `HEADLESS-*` outputs (`TABLET_CLEAN_HEADLESS=1` by default).
3. Creates a Hyprland headless output (`hyprctl output create headless`) and configures it to `1920x1080@60`.
4. Moves a new workspace to that output and ensures it has something to render by launching a helper window (defaults to Kitty with class `tablet-headless`).
5. Restarts `xdg-desktop-portal` + `xdg-desktop-portal-hyprland` after importing the current Wayland environment into the user systemd session.
6. Writes `~/.config/sunshine/sunshine.conf` with:
   - `output_name=<HEADLESS-N>`
   - `encoder=<SUNSHINE_ENCODER>`
   - `min_log_level=<SUNSHINE_MIN_LOG_LEVEL>`
   - `adapter_name=<SUNSHINE_ADAPTER>`
7. Starts Sunshine and logs to `./sunshine-tablet.log` (override with `TABLET_LOG_FILE`).

`./tablet.sh stop` removes all headless outputs, stops Sunshine, and closes helper windows created with class `tablet-headless`.

## Requirements

### Required

- Hyprland (Wayland) + `hyprctl`
- `jq`
- `xdg-desktop-portal` and `xdg-desktop-portal-hyprland`
- Sunshine

### Optional (but strongly recommended)

- `kitty` (default headless helper window; can be replaced via `TABLET_HEADLESS_CMD`)
- `wofi` (for `./tablet.sh menu`)
- `brightnessctl` (for brightness dim/restore)
- `libnotify` (`notify-send`)
- PipeWire utils for audio routing (`wpctl`) if you use `./tablet.sh audio`

## Setup (Arch Linux)

Package names vary by system; these are the typical ones:

- Core utilities: `jq`, `libnotify`
- UI helpers: `kitty`, `wofi`
- Brightness control: `brightnessctl`
- Portals: `xdg-desktop-portal`, `xdg-desktop-portal-hyprland`
- Audio (optional): `pipewire`, `wireplumber` (for `wpctl`)

Sunshine installation depends on your repo/AUR situation. After installing Sunshine, do the first-time setup (pairing PIN / apps / credentials) using Sunshine’s web UI as described in the Sunshine docs.

### Permissions note (brightness)

If `brightnessctl` fails, you may need to:

- use an appropriate udev rule, or
- ensure your user is in the correct group for the backlight device,

depending on how your system exposes backlight control.

## Quick start

From this folder:

```bash
chmod +x ./tablet.sh

./tablet.sh start
# connect with Moonlight

./tablet.sh status

./tablet.sh stop
```

Menu-driven UI (optional):

```bash
./tablet.sh menu
```

## USB tethering + Moonlight (end-to-end)

1. On your Android tablet, enable **USB tethering**.
2. Plug the tablet into the laptop via USB.
3. Confirm the laptop has an IP address on the tether interface.
4. Start host mode:

   ```bash
   ./tablet.sh start
   ```

5. In Moonlight (on the tablet):
   - Add the PC by the laptop’s tether IP.
   - Complete pairing with Sunshine (PIN prompt).
   - Start a stream.

Tip: if you want the “tablet screen” to be a dedicated workspace, leave the helper terminal running and open/move apps into that workspace.

## Configuration

This script is intentionally configured via environment variables so you can iterate quickly without editing code.

### Sunshine / capture

- `SUNSHINE_GPU_MODE`
  - `nvidia` (default): forces NVIDIA GL/EGL and `LIBVA_DRIVER_NAME=nvidia`.
  - `intel` / `mesa`: forces Mesa GL/EGL and tries to run on Intel (`iris`).
  - Purpose: helps align Sunshine’s GL/EGL stack with the compositor/capture pipeline to reduce DMA-BUF import issues.

- `SUNSHINE_ENCODER` (default: `software`)
  - The script currently defaults to software encoding because it’s the most reliable during debugging.

- `SUNSHINE_MIN_LOG_LEVEL` (default: `debug`)

- `SUNSHINE_ADAPTER`
  - Defaults based on `SUNSHINE_GPU_MODE`:
    - NVIDIA: `/dev/dri/renderD129`
    - Intel: `/dev/dri/renderD128`

Examples:

```bash
# Default (NVIDIA + software encoder)
./tablet.sh start

# Try Intel/Mesa GL/EGL for DMABUF compatibility testing
SUNSHINE_GPU_MODE=intel SUNSHINE_ENCODER=software ./tablet.sh start

# Write logs elsewhere
TABLET_LOG_FILE=/tmp/sunshine-tablet.log ./tablet.sh start
```

### Headless workspace content

- `TABLET_HEADLESS_CMD`
  - Command launched on the headless workspace to ensure there is always something visible.
  - Default launches:
    - `kitty --class tablet-headless --title Tablet-Headless ...`

Example:

```bash
TABLET_HEADLESS_CMD='kitty --class tablet-headless htop' ./tablet.sh start
```

### Headless cleanup behavior

- `TABLET_CLEAN_HEADLESS` (default: `1`)
  - When `1`, removes any existing `HEADLESS-*` outputs before creating a new one.
  - Set to `0` if you want to keep existing headless outputs.

## Commands

```text
./tablet.sh start    # create headless output + start Sunshine
./tablet.sh stop     # remove headless output(s) + stop Sunshine
./tablet.sh status   # show headless + Sunshine status
./tablet.sh swap     # swap workspaces between primary monitor and headless
./tablet.sh rotate   # rotate headless output between landscape/portrait-ish
./tablet.sh audio    # toggle PipeWire sink between laptop and Sunshine
./tablet.sh menu     # wofi menu for the above
```

## Troubleshooting

### Moonlight shows a black screen

1. **Confirm the headless workspace has content**:

   ```bash
   hyprctl clients -j | jq -r '.[] | select(.class == "tablet-headless") | .title'
   ```

   You should see at least one `tablet-headless` window.

2. **Check the Sunshine log** (`./sunshine-tablet.log`). Look for:
   - `dmabuf`, `import`, `modifier` messages
   - capture offsets (`[wlgrab] Offset: ...`)

3. **Try the other GPU mode**:

   ```bash
   ./tablet.sh stop
   SUNSHINE_GPU_MODE=intel SUNSHINE_ENCODER=software ./tablet.sh start
   ```

   If one mode produces import/modifier errors and the other doesn’t, that’s a strong signal you’re hitting a DMA-BUF/driver path mismatch.

### Headless output doesn’t show up for capture

- Portals must re-enumerate outputs. `tablet.sh` restarts them automatically.
- Verify services:

  ```bash
  systemctl --user status xdg-desktop-portal xdg-desktop-portal-hyprland
  ```

### Sunshine config keeps changing

This is expected: `tablet.sh` overwrites `~/.config/sunshine/sunshine.conf` every time you run `start`.

### Logs / debugging

- Script log target: `./sunshine-tablet.log` (ignored by git via `.gitignore`).
- You can increase verbosity further by keeping `SUNSHINE_MIN_LOG_LEVEL=debug`.

## Security / networking

Sunshine exposes streaming services on the network. For safety:

- Prefer using it on a trusted network, or
- restrict it to USB tethering / a private interface, and
- avoid exposing Sunshine ports to the public internet.

---

If you want, I can also add a small “Known-good settings for this machine” section (GPU device paths, render nodes, etc.) based on your current hybrid Intel/NVIDIA layout.
