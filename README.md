# Shifty

A native macOS menu bar app that nudges you to change posture throughout the day, rotating between standing, sitting, and any custom positions you add on a configurable, randomized schedule, with notifications at each change.

## Install

```bash
brew tap human37/shifty
brew install human37/shifty/shifty
brew services start human37/shifty/shifty
```

## Install (local development)

```bash
brew install --HEAD ./Formula/shifty.rb
brew services start shifty
```

## Service management

```bash
brew services list | rg shifty
brew services restart shifty
brew services stop shifty
```

## Configure options and interval

Shifty writes config and runtime state here:

```bash
~/Library/Application\ Support/Shifty/config.json
~/Library/Application\ Support/Shifty/state.json
```

Default `config.json` is:

```json
{
  "options": [
    { "label": "STAND", "icon": "🧍" },
    { "label": "SIT", "icon": "💺" }
  ],
  "intervalMinMinutes": 50,
  "intervalMaxMinutes": 70
}
```

To add more options or change interval:
1. Add options from menu: `Options` -> `Add Option...` (saved automatically), or edit `config.json` directly.
2. Restart service: `brew services restart shifty`.

`state.json` persists current option, queue, and next-change timestamp, so after restart/login Shifty resumes the same option and same time window.

## Publish a new version

Use the release script:

```bash
./scripts/release.sh 0.1.1
```

The script will:
- Push source updates to `human37/shifty`
- Create and push git tag `v0.1.1`
- Create a GitHub release (if missing)
- Update `human37/homebrew-shifty` formula `url` and `sha256`
- Push tap updates so users can `brew upgrade shifty`
