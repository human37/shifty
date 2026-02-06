# Shifty

Native macOS menu bar app that rotates posture prompts in the background.

## Install with Homebrew

```bash
brew install --HEAD ./Formula/shifty.rb
```

## Run as a background service

```bash
brew services start shifty
```

## Service management

```bash
brew services list | rg shifty
brew services restart shifty
brew services stop shifty
```
