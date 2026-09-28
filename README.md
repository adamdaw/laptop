# laptop

Bootstrap script for a fresh development machine:

- **Pop_OS 24.04 / Ubuntu 24.04** (and other Debian-family systems): apt
- **Bazzite / Fedora Atomic**: Homebrew, with rpm-ostree only for Ghostty — see [Bazzite](#bazzite--fedora-atomic)

The script detects the platform from `/etc/os-release` and `/run/ostree-booted`, then takes the matching path. Anything else stops with an "unsupported platform" error before it changes anything.

## Usage

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/adamdaw/laptop/main/linux)
```

Or clone and run locally:

```bash
git clone https://github.com/adamdaw/laptop.git
bash laptop/linux --dry-run   # print the plan, change nothing
bash laptop/linux
```

| Option | Effect |
|---|---|
| `-n`, `--dry-run` | Print every command that would run (installs, backups, stow, git config). Read-only checks still run so the plan is accurate. Nothing is changed. |
| `--print-os` | Print the detected platform (`debian` or `atomic`) and exit |
| `-h`, `--help` | Usage |

## What it installs

| Category | Ubuntu / Pop!_OS (apt unless noted) | Bazzite (Homebrew unless noted) |
|---|---|---|
| Shell | zsh, zsh-autosuggestions, zsh-syntax-highlighting, Starship (installer) | zsh, zsh-autosuggestions, zsh-syntax-highlighting, starship |
| Core | git, git-delta, curl, wget, build-essential, stow | git, git-delta, wget, stow (skipped when the image already has them) |
| Terminal | neovim, xclip, Ghostty (ghostty-ubuntu installer) | neovim, tmux (image), Ghostty (**rpm-ostree**, Terra) |
| Search | ripgrep, fd-find, fzf, bat | ripgrep, fd, fzf, bat |
| Data | jq | jq |
| GitHub | gh CLI (GitHub apt repo) | gh |
| Node | fnm (installer) + Node LTS, Claude Code | fnm + Node LTS, Claude Code |
| Python | uv (installer) | uv |
| JavaScript runtime | Bun (installer, `~/.bun`) | Bun (installer, `~/.bun`) |
| Font | JetBrains Mono Nerd Font (`~/.local/share/fonts`) | checked; installed to `~/.local/share/fonts` only if missing |

On Bazzite, a Homebrew formula is skipped when the command is already on `PATH` from the image (for example `tmux` and `git`).

## What it configures

- git: `core.hooksPath`, delta pager, `pull.rebase`, `push.autoSetupRemote`, `init.defaultBranch=main` — identity goes in `~/.laptop.local`
- SSH: generates `~/.ssh/id_ed25519` if absent
- Dotfiles: clones your dotfiles repo and stows `agy bash bat bin ghostty git nvim ripgrep ssh starship tmux zsh` — update `DOTFILES_REPO` at the top of `linux` to point at yours
- Shell: sets zsh as the login shell on Ubuntu/Pop!_OS. On Bazzite the login shell stays bash (see below).

### Dotfiles never use `stow --adopt`

`--adopt` moves existing files *into* the dotfiles repo, which silently replaces your tracked configs with whatever the distro shipped. Instead, before stowing each package the script finds any existing file in `$HOME` that the package would replace, and:

1. moves it to `~/.local/state/laptop/backups/<YYYYmmdd-HHMMSS>/<same path>`;
2. lists it in the summary at the end of the run.

Files that are already symlinks into the dotfiles repo are left alone. If a file sits under a directory that is a symlink to somewhere else, the script touches nothing and skips that package with a warning, so you can sort it out by hand. A package that fails to stow is reported as a warning; the script doesn't hide it.

This applies to both platforms. The Ubuntu path used to run `stow --adopt ... 2>/dev/null || true`.

## Bazzite / Fedora Atomic

Detected when `/etc/os-release` has `ID=bazzite`, or when `/run/ostree-booted` exists and the OS is Fedora (or `ID_LIKE` contains `fedora`). `/usr` is read-only there, so this path never uses `sudo`, apt, system keyrings or `chsh`.

### Install-order rule

Every tool comes from the first source in this list that can provide it:

1. **ujust recipe**, but only if it does exactly the job and doesn't touch stowed files. None qualify today. In particular the script never runs `ujust bazzite-cli`, because it appends a "bling" line to `~/.bashrc` / `~/.zshrc`. If that line is already in a file about to be stowed over, the script warns you: the line stays in the backup copy and won't be in the stowed file. The script doesn't edit either file.
2. **Homebrew**: CLI tools (`BREW_FORMULAE` in `linux`).
3. **Flatpak**: GUI apps. None are needed yet.
4. **rpm-ostree**: last resort, only when neither Homebrew nor Flatpak can close the gap. Each entry in `LAYERED_PACKAGES` has a comment explaining why.

### Layered packages

| Package | Why it's layered |
|---|---|
| `ghostty` | No Flatpak exists, and the Homebrew formula is macOS-only. Bazzite ships the [Terra](https://terra.fyralabs.com/) repo enabled, and Terra packages Ghostty. |

All layered packages go into **one** `rpm-ostree install --idempotent` transaction. A package is skipped if it's already installed, or if it's already layered and waiting for a reboot. If `rpm-ostree` fails (Terra mirrors have served bad metadata or checksums before), the script says so, suggests `rpm-ostree refresh-md --force`, and moves on. It doesn't retry in a loop.

### Reboot

A layered package is only usable after you reboot into the new deployment. The summary prints `Reboot required to use layered packages: ghostty` when that applies. **The script never reboots.** Run `systemctl reboot` when it suits you.

### Shell

zsh comes from Homebrew, and the login shell stays bash: no `chsh`, no `usermod`. Ghostty starts zsh through its `command =` setting, which lives in the dotfiles Ghostty config (for example `command = /home/linuxbrew/.linuxbrew/bin/zsh`). If that line is missing, the script warns you.

## Personal additions

Create `~/.laptop.local` before running. The script sources it at the end (under `--dry-run` it only says it would). Use it for anything personal: identity, private repo clones, bin symlinks.

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

On Ubuntu/Pop!_OS, the script disables ubuntu-report, popularity-contest and apport. On both platforms it turns off Go telemetry and npm fund messages. The dotfiles zshrc exports `DO_NOT_TRACK=1` and related opt-outs.

## Idempotent

Safe to re-run. Each step checks before acting: installed packages are skipped, already-stowed files are left alone, layered packages aren't layered twice, and an existing SSH key is kept.

## Tests

```bash
shellcheck linux tests/run.sh
tests/run.sh
```

`tests/run.sh` is a plain-bash harness that installs nothing. It runs `linux` with a throwaway `HOME` and a `PATH` of logging stubs (brew, rpm-ostree, stow, apt-get, sudo, …). The tests cover:

- platform detection;
- the `--dry-run` plan on Bazzite and Pop!_OS, including checks that nothing was executed and that `HOME` is unchanged;
- conflict backups and the bling-line warning;
- a stubbed real run followed by a re-run, to confirm idempotence;
- an rpm-ostree failure.

CI (`.github/workflows/ci.yml`) runs both commands on every push and pull request.
