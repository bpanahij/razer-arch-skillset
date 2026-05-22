# razer-arch-skillset

Claude Code skills for Razer Blade laptops running Arch Linux / [Omarchy](https://omarchy.org).

Powered by [`runkids/skillshare`](https://github.com/runkids/skillshare) — a Git-backed sync tool that symlinks skills into `~/.claude/skills/` (and any other AI CLIs you configure).

---

## Skills

| Skill | Slash command | What it does |
|---|---|---|
| `audio-setup` | `/razer-audio-setup` | Diagnose and fix speakers + DMIC on Razer Blade with ALC298 codec |
| `corne-keyboard` | `/razer-corne-keyboard` | Block built-in keyboard when Corne is plugged in; fix screen brightness keys via Razer proprietary HID; QMK flashing access |

More skills coming — PRs welcome.

---

## Quick start

```bash
# 1. Clone somewhere permanent
git clone git@github.com:bpanahij/razer-arch-skillset.git ~/.config/skillshare/skills/razer-arch-skillset

# 2. Install skillshare CLI if you don't have it
curl -fsSL https://raw.githubusercontent.com/runkids/skillshare/main/install.sh | bash

# 3. Track this repo
skillshare install git@github.com:bpanahij/razer-arch-skillset.git --track
skillshare sync --all
```

Or use `make install` if you also want the daily auto-update scheduler:

```bash
cd ~/.config/skillshare/skills/razer-arch-skillset
make install
```

After syncing, open a new Claude Code session — `/razer-audio-setup` and other skills will appear in the slash-command list.

---

## Updating

Skills update automatically once per day if you installed with `make install`. To pull immediately:

```bash
skillshare update --all && skillshare sync --all
```

---

## Contributing

Each skill lives in `skills/<name>/SKILL.md`. The frontmatter `name:` field becomes the slash-command name; `description:` is the one-liner shown in listings.

```
skills/
  audio-setup/
    SKILL.md        ← /razer-audio-setup
  <your-skill>/
    SKILL.md        ← /<your-skill>
```

Open a PR — no CI required, just a valid `SKILL.md` with `name` and `description` frontmatter.
