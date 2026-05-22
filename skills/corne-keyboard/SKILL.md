---
name: razer-corne-keyboard
description: Set up udev rules for the Corne keyboard on a Razer Blade running Arch Linux / Omarchy. Covers auto-disabling the built-in laptop keyboard when the Corne is plugged in (while keeping brightness keys working), re-enabling on unplug, screen brightness key fix via proprietary Razer HID, QMK firmware flashing access, and finding the correct USB vendor/product IDs. Use when the user asks about Corne keyboard setup, laptop keyboard conflict, udev rules, brightness keys, screen brightness not working, or QMK flashing permissions.
---

# /razer-corne-keyboard

Set up udev rules so the Corne keyboard works seamlessly: the built-in laptop keyboard is blocked automatically when the Corne is plugged in, and restored when unplugged. Screen brightness keys work at all times via a separate HID daemon. Also covers QMK flashing access.

## How it works

Two daemons run in parallel:

**`razer-brightness-passthrough`** — started/stopped by udev when the Corne is plugged in or unplugged. It uses `python-evdev` to exclusively grab the built-in keyboard (`/dev/input/eventX`), blocking all keystrokes from reaching Hyprland. On unplug it exits, releasing the grab.

**`razer-brightness-hid`** — runs permanently at boot. On the Razer Blade the screen brightness keys do **not** generate standard Linux input events (evdev). Instead the firmware sends proprietary Razer HID reports over the keyboard's raw HID interface (`/dev/hidrawX`). This daemon reads those reports, detects brightness up/down key codes, and calls `brightnessctl` directly.

### Why not evdev for brightness?

The Razer Blade EC firmware handles brightness key presses entirely at the hardware level with no ACPI notification to the OS. Monitoring all 28 `/dev/input/event*` devices (including `Intel HID events` and `Video Bus`) shows zero events when brightness keys are pressed. The proprietary Razer HID interface (hidraw) is the only path that reports them.

Report format on the brightness HID interface (16 bytes):
```
[0x01] [0x00] [0x43] [keycode] [second-key] [0x00 ...]
  keycode 0x42 = brightness UP
  keycode 0x41 = brightness DOWN
  keycode 0x00 = all released
```

### Why not sysfs inhibit for keyboard block?

`/sys/class/input/eventX/inhibited` blocks all events including brightness keys. The evdev exclusive grab approach is preferable because it lets the daemon selectively handle events (even though in practice brightness events come through hidraw, not evdev, on this model).

## What gets installed

| File | Purpose |
|---|---|
| `/etc/udev/rules.d/99-corne-keyboard.rules` | Starts/stops keyboard passthrough service on Corne plug/unplug |
| `/usr/local/bin/razer-brightness-passthrough` | Python daemon: grabs built-in keyboard while Corne is connected |
| `/etc/systemd/system/razer-brightness-passthrough.service` | Systemd service wrapping the passthrough daemon |
| `/usr/local/bin/razer-brightness-hid` | Python daemon: reads Razer HID brightness reports, drives brightnessctl |
| `/etc/systemd/system/razer-brightness-hid.service` | Systemd service wrapping the HID daemon (always enabled) |
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

## Step 2 — Install the keyboard passthrough daemon

This daemon grabs the built-in keyboard so Hyprland can't see it while the Corne is connected.

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
            # Brightness events don't actually arrive via evdev on the Razer Blade —
            # they come through the proprietary HID interface (see razer-brightness-hid).
            # This handler is kept as a safety net for other models.
            if event.type == ecodes.EV_KEY and event.code in BRIGHTNESS_KEYS:
                if event.value in (1, 2):
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

---

## Step 3 — Install the screen brightness HID daemon

On the Razer Blade, screen brightness keys do not generate standard Linux input events. The firmware sends proprietary HID reports over the raw HID interface instead. This daemon intercepts them.

```bash
sudo tee /usr/local/bin/razer-brightness-hid << 'PYEOF'
#!/usr/bin/env python3
"""
Monitor Razer laptop keyboard proprietary HID interface for brightness key reports
and drive intel_backlight directly via brightnessctl.

Report format (16 bytes):
  [0x01] [0x00] [0x43] [keycode] [optional-2nd-key] [0x00...]
  keycode 0x42 = brightness UP, 0x41 = brightness DOWN, 0x00 = all released
"""
import sys, os, time, signal, select, subprocess, glob

RAZER_VENDOR_PID = "00001532:000002B8"
REPORT_MAGIC  = (0x01, 0x00, 0x43)
KEY_UP_CODE   = 0x42
KEY_DOWN_CODE = 0x41
REPEAT_DELAY  = 0.15   # seconds between repeat calls while key is held

def find_backlight():
    for pattern in ['intel_backlight', 'acpi_video*']:
        matches = glob.glob(f'/sys/class/backlight/{pattern}')
        if matches:
            return os.path.basename(matches[0])
    entries = os.listdir('/sys/class/backlight')
    return entries[0] if entries else None

def find_razer_hidraw():
    paths = []
    for d in glob.glob('/sys/class/hidraw/hidraw*/'):
        try:
            uevent = open(os.path.join(d, 'device', 'uevent')).read()
            if RAZER_VENDOR_PID.upper() in uevent.upper():
                node = os.path.basename(d.rstrip('/'))
                paths.append(f'/dev/{node}')
        except OSError:
            pass
    return sorted(paths)

def set_brightness(backlight, step):
    subprocess.run(['brightnessctl', '-d', backlight, 'set', step],
                   capture_output=True)

def main():
    backlight = find_backlight()
    if not backlight:
        print("No backlight device found", file=sys.stderr)
        sys.exit(1)

    hidraw_paths = find_razer_hidraw()
    if not hidraw_paths:
        print("No Razer hidraw devices found — retrying in 3s", file=sys.stderr)
        time.sleep(3)
        hidraw_paths = find_razer_hidraw()
    if not hidraw_paths:
        sys.exit(1)

    fds = {}
    for path in hidraw_paths:
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            fds[fd] = path
        except OSError:
            pass

    if not fds:
        print("Could not open any Razer hidraw device", file=sys.stderr)
        sys.exit(1)

    state = {fd: (0x00, 0.0) for fd in fds}

    def cleanup(signum=None, frame=None):
        for fd in fds:
            try: os.close(fd)
            except: pass
        sys.exit(0)
    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    while True:
        readable, _, _ = select.select(list(fds.keys()), [], [], 5)
        for fd in readable:
            try:
                data = os.read(fd, 64)
            except OSError:
                continue
            if len(data) < 4:
                continue
            if data[0] != REPORT_MAGIC[0] or data[1] != REPORT_MAGIC[1] or data[2] != REPORT_MAGIC[2]:
                continue

            key = data[3]
            last_key, last_action_time = state[fd]
            now = time.monotonic()

            if key in (KEY_UP_CODE, KEY_DOWN_CODE):
                is_new_press = (last_key != key)
                is_repeat    = (now - last_action_time) >= REPEAT_DELAY
                if is_new_press or is_repeat:
                    step = '+5%' if key == KEY_UP_CODE else '5%-'
                    set_brightness(backlight, step)
                    state[fd] = (key, now)
            else:
                state[fd] = (0x00, last_action_time)

if __name__ == '__main__':
    main()
PYEOF

sudo chmod +x /usr/local/bin/razer-brightness-hid

sudo tee /etc/systemd/system/razer-brightness-hid.service << 'EOF'
[Unit]
Description=Razer laptop keyboard screen brightness key handler (HID)
After=systemd-udev-settle.service

[Service]
Type=simple
ExecStart=/usr/local/bin/razer-brightness-hid
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now razer-brightness-hid.service
```

---

## Step 4 — Install the Corne udev rule

Replace `4653` / `0001` with your actual VID:PID from Step 0 if different.

```bash
sudo tee /etc/udev/rules.d/99-corne-keyboard.rules << 'EOF'
ACTION=="add",    SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTRS{idVendor}=="4653", ATTRS{idProduct}=="0001", RUN+="/bin/systemctl start razer-brightness-passthrough.service"
ACTION=="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTRS{idVendor}=="4653", ATTRS{idProduct}=="0001", RUN+="/bin/systemctl stop razer-brightness-passthrough.service"
EOF

sudo udevadm control --reload-rules
```

Unplug and re-plug the Corne to test — built-in keyboard should be blocked, screen brightness keys should still work.

---

## Step 5 — Install QMK flashing rules

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
# HID brightness daemon is running (always):
systemctl status razer-brightness-hid.service

# Passthrough daemon is running (only while Corne is plugged in):
systemctl status razer-brightness-passthrough.service

# Screen brightness keys work — press brightness up/down on built-in keyboard:
# Brightness should change even with Corne plugged in.
watch -n0.5 cat /sys/class/backlight/intel_backlight/brightness

# Built-in keyboard is blocked (Hyprland can't see regular keystrokes):
# Try typing in a terminal while Corne is plugged in — it should produce no output.

# Udev rule fires on plug/unplug:
sudo udevadm monitor --environment --udev | grep -E "4653|systemctl"
```

---

## Troubleshooting

### Screen brightness keys don't work

Check the HID daemon is running and finding Razer devices:

```bash
systemctl status razer-brightness-hid.service
journalctl -u razer-brightness-hid.service -n 20
```

Verify the Razer hidraw devices are visible:

```bash
for d in /sys/class/hidraw/hidraw*/; do
  uevent="$d/device/uevent"
  name=$(grep HID_ID "$uevent" 2>/dev/null)
  echo "$(basename $d): $name"
done | grep -i 1532
```

If the daemon starts but brightness still doesn't change, confirm which backlight device is active:

```bash
ls /sys/class/backlight/
# Should show intel_backlight — test directly:
brightnessctl -d intel_backlight set 50%
```

### Built-in keyboard stays active after plugging in the Corne

Check that the passthrough service started:

```bash
systemctl status razer-brightness-passthrough.service
journalctl -u razer-brightness-passthrough.service -n 20
```

If the service fails with "keyboard not found", verify the device has `KEY_BRIGHTNESSUP` capability:

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

As a safety net, add to your shell rc:

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
