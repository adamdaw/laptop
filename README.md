# laptop

Bootstrap script for a fresh Pop_OS 24.04 / Ubuntu 24.04 machine.

## Usage

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/adamdaw/laptop/main/linux)
```

Or clone and run locally:

```bash
git clone https://github.com/adamdaw/laptop.git
bash laptop/linux
```

## What it installs

| Category | Tools |
|---|---|
| Shell | zsh, zsh-autosuggestions, zsh-syntax-highlighting, Starship |
| Core | git, git-delta, curl, wget, build-essential, stow |
| Terminal | neovim, xclip |
| Search | ripgrep, fd-find, fzf, bat |
| Data | jq |
| GitHub | gh CLI |
| Node | nvm + Node LTS, Claude Code |
| Python | uv |
| JavaScript runtime | Bun |
| Font | JetBrains Mono Nerd Font |

## What it configures

- git: user name/email, `core.hooksPath`, gh credential helper
- SSH: generates `~/.ssh/id_ed25519` if absent
- Dotfiles: clones [adamdaw/dotfiles](https://github.com/adamdaw/dotfiles) into `~/homeProjects/dotfiles` and stows all packages
- Shell: sets zsh as default

## Personal additions

Create `~/.laptop.local` before running — it's sourced at the end of the script. Use it for anything personal: identity, private repo clones, bin symlinks.

```bash
# ~/.laptop.local

# git identity (also needed in ~/.gitconfig.local — see dotfiles README)
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
git config --global credential."https://github.com".helper ""
git config --global --add credential."https://github.com".helper \
  "!/usr/bin/gh auth git-credential"

# Private repo clones
clone_if_absent "https://github.com/you/your-repo.git" "$HOME_PROJECTS_DIR/your-repo"

# ~/bin symlinks
mkdir -p "$HOME/bin"
symlink_bin "$HOME_PROJECTS_DIR/your-repo/bin/your-script" "$HOME/bin/your-script"

# Anacron — user-level job scheduler (survives sleep/wake cycles)
# Step 1: add to crontab (crontab -e):
#   @hourly /usr/sbin/anacron -s -t ~/.anacron/etc/anacrontab -S ~/.anacron/spool
# Step 2: create ~/.anacron/etc/anacrontab:
mkdir -p ~/.anacron/etc ~/.anacron/spool
cat > ~/.anacron/etc/anacrontab << 'ANACRONTAB'
SHELL=/bin/bash
PATH=/home/you/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOME=/home/you
LOGNAME=you

1  5  daily-digest             /home/you/bin/daily-digest >> ~/.local/share/daily-digest.log 2>&1
1  10 commonplace-daily-commit /home/you/bin/commonplace-daily-commit.sh
ANACRONTAB
```

## Telemetry

Disables ubuntu-report, popularity-contest, apport, go telemetry, and npm fund messages. The dotfiles zshrc exports `DO_NOT_TRACK=1` and related opt-outs.

## Idempotent

Safe to re-run. Each step checks before acting.
