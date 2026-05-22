---
name: razer-corne-keyboard
description: Set up udev rules for the Corne keyboard on a Razer Blade running Arch Linux / Omarchy. Covers auto-disabling the built-in laptop keyboard when the Corne is plugged in (while keeping brightness keys working), re-enabling on unplug, QMK firmware flashing access, and finding the correct USB vendor/product IDs. Use when the user asks about Corne keyboard setup, laptop keyboard conflict, udev rules, brightness keys, or QMK flashing permissions.
---

# /razer-corne-keyboard

Set up udev rules so the Corne keyboard works seamlessly: the built-in laptop keyboard is blocked automatically when the Corne is plugged in (but brightness keys still work), and restored when unplugged. Also covers QMK flashing access.

## How it works

The built-in keyboard is grabbed exclusively by a Python daemon (`razer-brightness-passthrough`) using `python-evdev`. This prevents all keystrokes from reaching Hyprland while intercepting `KEY_BRIGHTNESSUP` and `KEY_BRIGHTNESSDOWN` and handling them directly via `brightnessctl`. On unplug, the daemon exits, releases the grab, and Hyprland resumes reading from the built-in keyboard normally.

This approach is preferable to `sysfs inhibit` (`/sys/class/input/eventX/inhibited`) because inhibit blocks all events including brightness keys. Direct `brightnessctl` invocation is preferable to forwarding to a uinput virtual device because Wayland compositors may not reliably route uinput keyboard events through their keybind dispatch chain.

## What gets installed

| File | Purpose |
|---|---|
| `/etc/udev/rules.d/99-corne-keyboard.rules` | Starts/stops brightness passthrough service on plug/unplug |
| `/usr/local/bin/razer-brightness-passthrough` | Python daemon: grabs keyboard, runs brightnessctl for brightness keys |
| `/etc/systemd/system/razer-brightness-passthrough.service` | Systemd service wrapping the daemon |
| `/etc/udev/rules.d/50-qmk.rules` | Grants userspace access to QMK bootloaders for flashing |

---

## Step 0 — Find the Corne's USB vendor and product IDs

Plug in the Corne, then run:

```bash
lsusb | grep -i "corne\|foostan\|4653\|keeb"
# or scan everything plugged in recently:
sudo dmesg | grep -i "idVendor\|idProduct\|corne\|usb.*new" | tail -20
# or enumerate directly:
for d in /sys/bus/usb/devices/*/; do
  v=$(cat "$d/idVendor" 2>/dev/null)
  p=$(cat "$d/idProduct" 2>/dev/null)
  mfr=$(cat "$d/manufacturer" 2>/dev/null)
  prod=$(cat "$d/product" 2>/dev/null)
  [[ -n "$v" ]] && echo "$v:$p  $mfr $prod"
done | sort -u
```

The Corne keyboard (crkbd) with common firmware defaults:
- **Vendor `4653`, Product `0001`** — foostan/crkbd default VID:PID (current setup)

If your IDs differ, substitute them everywhere below.

---

## Step 1 — Install required packages

```bash
sudo pacman -S --needed python-evdev alsa-utils alsa-tools
```

---

## Step 2 — Install the brightness passthrough daemon

```bash
sudo tee /usr/local/bin/razer-brightness-passthrough << 'PYEOF'
#!/usr/bin/env python3
import sys, time, signal, subprocess, glob, os, evdev
from evdev import ecodes

RAZER_VENDOR = 0x1532
RAZER_PRODUCT = 0x02b8
BRIGHTNESS_KEYS = {ecodes.KEY_BRIGHTNESSUP, ecodes.KEY_BRIGHTNESSDOWN}

def find_backlight():
    for pattern in ['amdgpu_bl*', 'intel_backlight', 'acpi_video*']:
        matches = glob.glob(f'/sys/class/backlight/{pattern}')
        if matches:
            return os.path.basename(matches[0])
    devices = os.listdir('/sys/class/backlight')
    return devices[0] if devices else None

def find_device():
    for path in evdev.list_devices():
        try:
            dev = evdev.InputDevice(path)
            if dev.info.vendor == RAZER_VENDOR and dev.info.product == RAZER_PRODUCT:
                caps = dev.capabilities().get(ecodes.EV_KEY, [])
                if ecodes.KEY_BRIGHTNESSUP in caps:
                    return dev
            dev.close()
        except (PermissionError, OSError):
            pass
    return None

def main():
    dev = None
    for _ in range(30):
        dev = find_device()
        if dev: break
        time.sleep(0.1)
    if not dev:
        print("Razer keyboard with brightness keys not found", file=sys.stderr)
        sys.exit(1)

    backlight = find_backlight()
    if not backlight:
        print("No backlight device found", file=sys.stderr)
        sys.exit(1)

    dev.grab()

    def cleanup(signum=None, frame=None):
        try: dev.ungrab()
        except: pass
        sys.exit(0)
    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    try:
        for event in dev.read_loop():
            if event.type == ecodes.EV_KEY and event.code in BRIGHTNESS_KEYS:
                if event.value in (1, 2):  # key-down and key-repeat
                    step = '+5%' if event.code == ecodes.KEY_BRIGHTNESSUP else '5%-'
                    subprocess.run(
                        ['brightnessctl', '-d', backlight, 'set', step],
                        capture_output=True
                    )
    except OSError:
        pass
    finally:
        cleanup()

if __name__ == "__main__":
    main()
PYEOF

sudo chmod +x /usr/local/bin/razer-brightness-passthrough

sudo tee /etc/systemd/system/razer-brightness-passthrough.service << 'EOF'
[Unit]
Description=Razer built-in keyboard brightness passthrough (active while Corne is connected)

[Service]
Type=simple
ExecStart=/usr/local/bin/razer-brightness-passthrough
Restart=no
EOF

sudo systemctl daemon-reload
```

Test it manually:

```bash
sudo systemctl start razer-brightness-passthrough.service
sudo systemctl status razer-brightness-passthrough.service   # should be active (running)
# Try the built-in keyboard — regular keys should be blocked
# Try the brightness keys — should still work
sudo systemctl stop razer-brightness-passthrough.service
# Built-in keyboard should now work normally again
```

---

## Step 3 — Install the Corne udev rule

Replace `4653` / `0001` with your actual VID:PID from Step 0 if different.

```bash
sudo tee /etc/udev/rules.d/99-corne-keyboard.rules << 'EOF'
ACTION=="add",    SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTRS{idVendor}=="4653", ATTRS{idProduct}=="0001", RUN+="/bin/systemctl start razer-brightness-passthrough.service"
ACTION=="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTRS{idVendor}=="4653", ATTRS{idProduct}=="0001", RUN+="/bin/systemctl stop razer-brightness-passthrough.service"
EOF

sudo udevadm control --reload-rules
```

Unplug and re-plug the Corne to test — built-in keyboard should be blocked, brightness keys should still work.

---

## Step 4 — Install QMK flashing rules

These grant your user account access to the keyboard's bootloader so `qmk flash` works without sudo.

```bash
# Download the official QMK udev rules:
sudo curl -fsSL https://raw.githubusercontent.com/qmk/qmk_firmware/master/util/udev/50-qmk.rules \
  -o /etc/udev/rules.d/50-qmk.rules

sudo udevadm control --reload-rules
sudo udevadm trigger
```

Add yourself to the `plugdev` group if not already a member (required for `hidraw` access):

```bash
sudo usermod -aG plugdev $USER
# log out and back in for the group to take effect
```

Verify:

```bash
groups | grep plugdev
```

---

## Verification

```bash
# Service is running while Corne is plugged in:
systemctl status razer-brightness-passthrough.service

# Built-in keyboard is grabbed (Hyprland can't see regular keystrokes):
# Just try typing in a terminal — it should produce no output while service is running

# Brightness keys work — press Fn+brightness on the built-in keyboard:
# Screen brightness should change. brightnessctl is called directly by the daemon.

# Udev rule fires on plug/unplug — watch events:
sudo udevadm monitor --environment --udev | grep -E "4653|systemctl"
```

---

## Troubleshooting

### Built-in keyboard stays active after plugging in the Corne

Check that the service started:

```bash
systemctl status razer-brightness-passthrough.service
journalctl -u razer-brightness-passthrough.service -n 20
```

If the service fails with "keyboard not found", check the VID:PID in the udev rule matches `lsusb` output, and verify the device has `KEY_BRIGHTNESSUP` capability:

```bash
sudo python3 -c "
import evdev
for p in evdev.list_devices():
    d = evdev.InputDevice(p)
    if d.info.vendor == 0x1532:
        print(p, d.name, hex(d.info.vendor), hex(d.info.product))
        print('  brightness:', evdev.ecodes.KEY_BRIGHTNESSUP in d.capabilities().get(evdev.ecodes.EV_KEY, []))
"
```

### Built-in keyboard stays blocked after unplugging the Corne

The `remove` rule may not have fired (abrupt disconnect). Stop the service manually:

```bash
sudo systemctl stop razer-brightness-passthrough.service
```

As a safety net, the service can be stopped at login by adding to your shell rc:

```bash
# Release keyboard grab if Corne was disconnected without clean udev remove
systemctl is-active razer-brightness-passthrough.service &>/dev/null && sudo systemctl stop razer-brightness-passthrough.service
```

### `qmk flash` fails with permission denied

```bash
# Check the device node permissions:
ls -la /dev/bus/usb/$(lsusb | grep -i "qmk\|4653\|03eb" | awk '{print $2"/"substr($4,1,3)}')

# Reload rules and re-trigger:
sudo udevadm control --reload-rules && sudo udevadm trigger

# Confirm plugdev membership:
groups | grep plugdev
```

### Finding the bootloader VID:PID for flashing

Put the Corne into bootloader mode (usually double-tap the reset button), then:

```bash
lsusb   # look for a new device — common bootloaders:
        # 03eb:2ff4  ATmega32U4 DFU
        # 16c0:0478  PJRC HalfKay (Teensy)
        # 1209:2302  pid.codes shared (Keyboardio)
```

That device should already be covered by `50-qmk.rules`.
