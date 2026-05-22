---
name: razer-audio-setup
description: Diagnose and fix audio on a Razer Blade running Arch Linux / Omarchy. Covers the ALC298 speaker amp init (hda-verb), SOF vs legacy HDA driver choice, DMIC (digital mic) setup, and boot persistence via systemd. Use when the user says speakers or mic aren't working, audio is silent, or asks to set up or fix sound on the Razer Blade.
---

# /razer-audio-setup

Diagnose and fix audio on a Razer Blade running Arch Linux / Omarchy, then make it persist across reboots.

## Background

Razer Blade laptops with the Realtek ALC298 codec require ~2000 vendor-specific register writes to initialize the speaker amplifier. The Linux kernel's generic HDA driver does not apply these — no upstream quirk exists for the Razer Blade 18 (subsystem `1a58:300c`) or most Razer Blade models. Audio data reaches the codec correctly but the physical amplifier stays silent.

Two complementary fixes are needed:

| Component | Problem | Fix |
|---|---|---|
| Speakers | ALC298 amp not initialized | Run hda-verb init script at boot |
| DMIC (built-in mic array) | Requires SOF DSP driver | Keep SOF enabled (do **not** use `dmic_detect=0`) |
| Headphone jack (audio + mic) | Works with either driver | No action needed |

## Step 0 — Diagnose the current state

```bash
# Which driver is handling the internal audio?
sudo dmesg | grep -E "snd_hda_intel|sof-audio|using SOF" | head -5

# What cards and sinks does PipeWire see?
pactl list sinks short
pactl list sources short

# Is audio data reaching the codec? (stream != 0 means active)
cat /proc/asound/card*/codec#0 2>/dev/null | grep -A5 "Speaker Playback Volume" | grep "Converter"

# Are all GPIOs disabled? (expected — GPIO is not the issue for ALC298)
cat /proc/asound/card*/codec#0 2>/dev/null | grep -A5 "^GPIO"

# Quick volume/mute check
pactl get-sink-mute @DEFAULT_AUDIO_SINK@
pactl get-sink-volume @DEFAULT_AUDIO_SINK@
```

**Expected good state with SOF active:**
- dmesg shows `Digital mics found on Skylake+ platform, using SOF driver`
- ALC298 appears on **card 1** (`/dev/snd/hwC1D0`)
- Speakers are silent until hda-verb init runs

**Expected good state after the full fix:**
- Speakers produce sound
- DMIC appears as a source in `pactl list sources short`
- `razer-audio-init.service` is enabled and has run at boot

---

## Step 1 — Ensure SOF is enabled (do NOT add dmic_detect=0)

If `/etc/modprobe.d/audio_fixes.conf` exists and contains `dmic_detect=0`, remove it:

```bash
sudo rm -f /etc/modprobe.d/audio_fixes.conf
sudo mkinitcpio -P
```

Then reboot. After reboot the ALC298 will be on card 1 (`hwC1D0`) and DMIC will be present — but speakers will be silent until Step 2.

---

## Step 2 — Install the hda-verb speaker amp init

### 2a. Install required packages

```bash
sudo pacman -S --needed alsa-utils alsa-tools
```

- `alsa-utils` — provides `amixer`, `speaker-test`, `alsactl`
- `alsa-tools` — provides `hda-verb`

### 2b. Download the init script

```bash
curl -fsSL https://raw.githubusercontent.com/malstor/razer-2024-linux-fixes/main/rb-23-24-sound-fix.sh \
  -o /tmp/rb-sound-fix.sh
```

The script targets `hwC1D0` (SOF card 1). If SOF is active this is correct — do **not** change it to `hwC0D0`.

### 2c. Test it immediately (no reboot needed)

```bash
sudo bash /tmp/rb-sound-fix.sh
```

Play a test tone to confirm speakers work:

```bash
python3 -c "
import struct, math, wave
rate, freq, dur = 44100, 440, 2
s = [int(32767*math.sin(2*math.pi*freq*i/rate)) for i in range(rate*dur)]
with wave.open('/tmp/test_tone.wav','w') as f:
    f.setnchannels(2); f.setsampwidth(2); f.setframerate(rate)
    stereo=[]; [stereo.extend([x,x]) for x in s]
    f.writeframes(struct.pack(f'{len(stereo)}h',*stereo))
"
paplay /tmp/test_tone.wav
```

### 2d. Install for persistence

```bash
sudo cp /tmp/rb-sound-fix.sh /usr/local/bin/razer-audio-init.sh
sudo chmod +x /usr/local/bin/razer-audio-init.sh

sudo tee /etc/systemd/system/razer-audio-init.service << 'EOF'
[Unit]
Description=Razer Blade ALC298 speaker amp initialization
After=sound.target

[Service]
Type=oneshot
# Wait for the SOF HDA hwdep device before sending verbs
ExecStartPre=/bin/bash -c 'until [ -e /dev/snd/hwC1D0 ]; do sleep 0.1; done'
ExecStart=/usr/local/bin/razer-audio-init.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable razer-audio-init.service
```

---

## Step 3 — Verify after next reboot

```bash
# Service ran successfully?
systemctl status razer-audio-init.service

# Both mics visible?
pactl list sources short | grep -v monitor

# Speakers audible?
paplay /tmp/test_tone.wav    # regenerate with python3 snippet above if tmp was cleared
```

---

## Troubleshooting

### Speakers work manually but not after reboot

The service may have run before the hwdep device was ready. Restart it:

```bash
sudo systemctl restart razer-audio-init.service
paplay /tmp/test_tone.wav
```

If this is a recurring issue, increase the wait timeout in the service:

```bash
# Change the ExecStartPre line to:
ExecStartPre=/bin/bash -c 'for i in $(seq 50); do [ -e /dev/snd/hwC1D0 ] && exit 0; sleep 0.2; done; exit 1'
```

### DMIC not appearing as a source

Confirm SOF is active (card 1 = `sof-hda-dsp`):

```bash
cat /proc/asound/cards | grep -i sof
```

If SOF is missing, check for `dmic_detect=0` in `/etc/modprobe.d/` and remove it.

### Wrong card number after a kernel update

If the card numbering changes (e.g. ALC298 moves from `hwC1D0` to `hwC0D0`), update the script path in the service:

```bash
ls /dev/snd/hwC*D0
# identify which one is the ALC298:
cat /proc/asound/card*/codec#0 | grep -B1 "ALC298"
# update ExecStart in the service accordingly
sudo systemctl daemon-reload && sudo systemctl restart razer-audio-init.service
```

### No sound from headphone jack

The headphone jack uses the same ALC298 codec. If headphones are silent, confirm the jack is not falsely detected as inserted, which would trigger auto-mute:

```bash
amixer -c 1 sget "Auto-Mute Mode"          # should be Disabled or Enabled
pactl list cards | grep -A5 "Headphone"    # availability: no = not plugged in
```

---

## References

- Community fix script: https://github.com/malstor/razer-2024-linux-fixes
- Kernel bug tracker: https://bugzilla.kernel.org/show_bug.cgi?id=207423
- ALC298 subsystem ID for Razer Blade 18 (RZ09-0509): `1a58:300c`
