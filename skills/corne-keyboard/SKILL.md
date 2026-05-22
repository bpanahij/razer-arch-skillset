---
name: razer-corne-keyboard
description: Set up udev rules for the Corne keyboard on a Razer Blade running Arch Linux / Omarchy. Covers auto-disabling the built-in laptop keyboard when the Corne is plugged in, re-enabling it on unplug, QMK firmware flashing access, and finding the correct USB vendor/product IDs. Use when the user asks about Corne keyboard setup, laptop keyboard conflict, udev rules, or QMK flashing permissions.
---

# /razer-corne-keyboard

Set up udev rules so the Corne keyboard works seamlessly: the built-in laptop keyboard disables automatically when the Corne is plugged in and re-enables when it's unplugged. Also covers QMK flashing access.

## What gets installed

| File | Purpose |
|---|---|
| `/etc/udev/rules.d/99-corne-keyboard.rules` | Triggers keyboard toggle on plug/unplug |
| `/usr/local/bin/toggle-laptop-keyboard` | Inhibits/restores the Razer built-in keyboard via sysfs |
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

## Step 1 — Install the toggle script

```bash
sudo tee /usr/local/bin/toggle-laptop-keyboard << 'EOF'
#!/bin/bash
# 0 = enable, 1 = disable
VALUE="${1:-1}"

in_razer=0
while IFS= read -r line; do
    if [[ "$line" == N:* ]]; then
        if [[ "$line" == *'Razer Razer Blade'* ]]; then
            in_razer=1
        else
            in_razer=0
        fi
    elif [[ "$in_razer" == 1 && "$line" == H:*kbd*event* ]]; then
        event=$(echo "$line" | grep -oP 'event\d+')
        [[ -z "$event" ]] && continue
        input_dir=$(dirname "$(readlink -f "/sys/class/input/$event")")
        [[ -f "$input_dir/inhibited" ]] && echo "$VALUE" > "$input_dir/inhibited"
    fi
done < /proc/bus/input/devices
EOF

sudo chmod +x /usr/local/bin/toggle-laptop-keyboard
```

Test it manually before wiring up udev:

```bash
# Disable built-in keyboard (should stop responding to keypresses):
sudo /usr/local/bin/toggle-laptop-keyboard 1
# Re-enable:
sudo /usr/local/bin/toggle-laptop-keyboard 0
```

---

## Step 2 — Install the Corne udev rule

Replace `4653` / `0001` with your actual VID:PID from Step 0 if different.

```bash
sudo tee /etc/udev/rules.d/99-corne-keyboard.rules << 'EOF'
ACTION=="add",    SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTRS{idVendor}=="4653", ATTRS{idProduct}=="0001", RUN+="/usr/local/bin/toggle-laptop-keyboard 1"
ACTION=="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTRS{idVendor}=="4653", ATTRS{idProduct}=="0001", RUN+="/usr/local/bin/toggle-laptop-keyboard 0"
EOF

sudo udevadm control --reload-rules
```

Unplug and re-plug the Corne to test — the built-in keyboard should go silent.

---

## Step 3 — Install QMK flashing rules

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
# Rules are loaded:
sudo udevadm test $(udevadm info -q path -n /dev/bus/usb/$(lsusb | grep 4653 | awk '{print $2"/"substr($4,1,3)}')) 2>&1 | grep -i "toggle\|run\|corne"

# Inhibit sysfs nodes exist for the built-in keyboard:
grep -A5 'Razer Razer Blade' /proc/bus/input/devices | grep "H:.*kbd"

# Current inhibit state (0 = active, 1 = inhibited):
for e in /sys/class/input/event*/; do
  inh="$e/inhibited"
  name=$(cat "$(dirname $(readlink -f $e))/name" 2>/dev/null)
  [[ -f "$inh" && "$name" == *Razer* ]] && echo "$name: $(cat $inh)"
done
```

---

## Troubleshooting

### Built-in keyboard stays active after plugging in the Corne

Check that the rule fires and the script runs:

```bash
# Watch udev events while plugging in the Corne:
sudo udevadm monitor --environment --udev | grep -E "4653|toggle|corne"
```

If the rule doesn't fire, confirm the VID:PID matches:

```bash
lsusb   # look for the Corne entry and compare with the rule
```

If the rule fires but the keyboard stays on, run the script manually with debug output:

```bash
sudo bash -x /usr/local/bin/toggle-laptop-keyboard 1
```

Look for the `event\d+` match — if it's empty, the Razer keyboard node name in `/proc/bus/input/devices` might differ. Check:

```bash
grep -A10 'Razer' /proc/bus/input/devices | grep "^N:"
```

Update the `'Razer Razer Blade'` string in the script to match.

### Built-in keyboard stays disabled after unplugging the Corne

The `remove` rule may not have fired (e.g. abrupt disconnect). Re-enable manually:

```bash
sudo /usr/local/bin/toggle-laptop-keyboard 0
```

To make this automatic at login as a safety net, add to your shell rc:

```bash
# Re-enable built-in keyboard on login (in case it was left inhibited)
/usr/local/bin/toggle-laptop-keyboard 0
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
