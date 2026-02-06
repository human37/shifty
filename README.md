# Shifty

Native macOS menu bar app that rotates posture prompts in the background.

## Install (public)

```bash
brew tap human37/shifty
brew install shifty
brew services start shifty
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
