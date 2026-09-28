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
| `-n`, `--dry-run` | Print every command that would run (installs, backups, stow, git config). Read-only checks (`brew list`, `rpm -q`, `rpm-ostree status`, `fc-list`, `dpkg -s`) still run so the plan is accurate. `mise` is never executed during a dry run on either platform, not even `mise --version`, because mise creates state and cache directories whenever it runs. Whether mise and Node are already installed is read from disk instead: mise on `PATH` or in `~/.local/bin`, the `node` pin in mise's global config (parsed as TOML with python3's `tomllib`), an executable `node` installed under mise's data dir that matches that pin, and mise's `node`/`npm` shims. Nothing is changed. |
| `--print-os` | Print the detected platform (`debian` or `atomic`) and exit |
| `-h`, `--help` | Usage |

## What it installs

| Category | Ubuntu / Pop!_OS (apt unless noted) | Bazzite (Homebrew unless noted) |
|---|---|---|
| Shell | zsh, zsh-autosuggestions, zsh-syntax-highlighting, Starship (installer) | zsh, zsh-autosuggestions, zsh-syntax-highlighting, starship |
| Core | git, git-delta, curl, gpg, wget, build-essential, stow | git, git-delta, wget, stow (skipped when the image already has them) |
| Terminal | neovim, xclip, Ghostty (ghostty-ubuntu installer) | neovim, tmux (image), Ghostty (**rpm-ostree**, Terra) |
| Search | ripgrep, fd-find, fzf, bat | ripgrep, fd, fzf, bat |
| Data | jq | jq |
| GitHub | gh CLI (GitHub apt repo) | gh |
| Node | mise (mise's apt repo) + Node LTS, Claude Code | mise + Node LTS, Claude Code |
| Python | uv (installer) | uv |
| JavaScript runtime | Bun (installer, `~/.bun`) | Bun (installer, `~/.bun`) |
| Font | JetBrains Mono Nerd Font (`~/.local/share/fonts`) | checked; installed to `~/.local/share/fonts` only if missing |

On Bazzite, a Homebrew formula is skipped when the command is already on `PATH` from the image (for example `tmux` and `git`).

### Node comes from mise

[mise](https://mise.jdx.dev) manages Node; the dotfiles already activate it in bash and zsh. mise is installed from the first source in the install-order rule: the Homebrew formula on Bazzite, and mise's official apt repo (`mise.jdx.dev/deb`, signed with mise's key) on Ubuntu/Pop!_OS. The key is dearmored into a temp file and installed with mode 0644, and the sources file is made 0644, so both are always readable by apt. If the key download or the dearmor fails, the run stops before any repo is added, and no empty keyring is left behind. The apt repo was chosen over the `mise.run` installer because apt verifies signatures and `apt-get upgrade` keeps mise current, the same way the gh repo works. A mise that is already on `PATH` or in `~/.local/bin` (where `mise.run` puts it) is used as is.

Node LTS is installed with `mise use -g node@lts`. **That writes `~/.config/mise/config.toml`** (mise's global config; `MISE_GLOBAL_CONFIG_FILE` / `MISE_CONFIG_DIR` / `XDG_CONFIG_HOME` move it). The dotfiles don't manage that file today. If a dotfiles `mise` package takes it over later, pin Node there. The script never writes the file when its path resolves into the dotfiles repo, or when that path can't be resolved; it warns instead.

The global config is parsed as real TOML with python3's standard-library `tomllib` (Python 3.11+, which Bazzite and Ubuntu 24.04 ship). No hand-written parser is involved, so every valid form of a pin counts: `[tools]` / `["tools"]` tables, `node.version = "…"`, `[tools.node]`, inline tables, `core:node`, and multiline strings that happen to contain a `[tools]` line. There are three outcomes:

- **No file, or no `tools.node` entry:** node is not pinned, so `mise use -g node@lts` may pin it.
- **A `tools.node` entry, in any form:** node is pinned, and **the pin is never changed.** When the entry is one version string (directly or as `version = "…"`), that version is used to check what is installed.
- **Uncertain:** python3 or `tomllib` is missing, or the file can't be read or parsed. The config is never written and Node isn't installed. The script warns you to fix the file, or to pin node yourself, and then re-run.

Node counts as installed only when an **executable** `node` exists for the pinned version: `installs/node/<pin>` (a version, or the prefix/alias links mise makes, such as `22` or `lts`), or `installs/node/<pin>.*` for a numeric prefix. mise's `node`/`npm` shims must exist too. If the disk can't prove that, the script *reconciles*: it runs `mise install node` and then `mise reshim`, and never changes the pin. Examples are a pin of `20` with only 22 installed, a pin whose version isn't a single string (such as a list), or missing shims. Each command has its own warning if it fails.

**Reconciling can repeat, and it isn't free.** Take a pin of `lts`: it is proven only by the `installs/node/lts` link, which mise makes when an alias matches an installed version. If that link isn't there, **every run** reconciles again. `mise install node` then has to resolve what `lts` means today, which can hit the network (mise's version index). If a newer LTS is out, it installs that version too. So a re-run isn't guaranteed to be a no-op. The config is still never changed.

Claude Code is installed only with mise's own npm shim (`~/.local/share/mise/shims/npm`), and only once that Node is known to work. npm puts `claude` into that Node's own `bin` directory, so the script then runs `mise reshim` to give it a shim on `PATH` (with its own warning if that fails). If Node isn't ready (the config is uncertain or the write was blocked, mise failed, or the shims are missing), the script skips Claude Code with a warning. It never falls back to another `npm` on `PATH`. The same applies to the npm `fund` setting.

fnm is no longer installed. An existing fnm (`~/.local/share/fnm`, or `fnm` on `PATH`) is left alone and only noted in the output. Remove it yourself when you no longer need it.

## What it configures

- git: `core.hooksPath`, delta pager, `pull.rebase`, `push.autoSetupRemote`, `init.defaultBranch=main` — identity goes in `~/.laptop.local`
- SSH: generates `~/.ssh/id_ed25519` if absent
- Dotfiles: clones your dotfiles repo and stows `agy bash bat bin ghostty git nvim ripgrep ssh starship tmux zsh` — update `DOTFILES_REPO` at the top of `linux` to point at yours
- Shell: sets zsh as the login shell on Ubuntu/Pop!_OS. On Bazzite the login shell stays bash (see below).

### Dotfiles never use `stow --adopt`

`--adopt` moves existing files *into* the dotfiles repo, which silently replaces your tracked configs with whatever the distro shipped. Instead, before stowing each package the script finds any existing file in `$HOME` that the package would replace, and:

1. moves it to `~/.local/state/laptop/backups/<YYYYmmdd-HHMMSS>.<random>/<same path>`. Each run gets its own directory (made with `mktemp -d`), so two runs in the same second never share one. The move uses `mv -n` and refuses a destination that already exists;
2. lists it in the summary at the end of the run.

A conflict can also be an *ancestor*: for example `~/.config/nvim` is a regular file while the package needs `~/.config/nvim/init.lua`. The script backs up that file. Anything that already resolves into the dotfiles repo is left alone and handed to stow. This test is repository membership: it doesn't prove that stow made the link. It covers directories stow folded into this package or into *another* package of the same repo (e.g. `~/.config` → `agy/.config`), and it also covers links you made into the repo by hand. Nothing inside the repo is ever moved. Stow unfolds a directory link into one of its packages. It reports any other clash, such as a hand-made `~/.tmux.conf` → `bash/.bashrc`, as a conflict, and the script lists that package as a failed stow. If a backup fails (the directory can't be created, or the move fails or has no effect), the script warns and skips stowing that package. If a file sits under a directory that is a symlink to somewhere else, the script touches nothing and skips that package with a warning, so you can sort it out by hand. A package that fails to stow is reported as a warning; the script doesn't hide it.

This applies to both platforms. The Ubuntu path used to run `stow --adopt ... 2>/dev/null || true`.

## Bazzite / Fedora Atomic

Detected when `/etc/os-release` has `ID=bazzite`, or when `/run/ostree-booted` exists and the OS is Fedora (or `ID_LIKE` contains `fedora`). `/usr` is read-only there, so this path never uses `sudo`, apt, system keyrings or `chsh`.

**Prerequisite: Homebrew.** Bazzite ships Homebrew in the image (`/home/linuxbrew/.linuxbrew`), so the script expects it and does not install it. If `brew` isn't on `PATH`, the script looks in the standard prefixes and loads `brew shellenv`. If it still can't find Homebrew, a real run stops with an error before changing anything. A `--dry-run` warns and prints the full plan anyway. On a Fedora Atomic image without Homebrew, install it from [brew.sh](https://brew.sh) first.

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

All layered packages go into **one** `rpm-ostree install --idempotent` transaction. A package is skipped if it's already installed, or if it's already layered and waiting for a reboot. `rpm-ostree status --json` is read structurally with `python3`: a package counts only if it's in `requested-packages` or `packages` of the **booted** deployment or a **staged/pending** one (listed before the booted one). A package that exists only in the rollback deployment doesn't count. If the status can't be read, the script falls back to `rpm-ostree install --idempotent`, which does nothing for a package that's already requested. If `rpm-ostree` fails (Terra mirrors have served bad metadata or checksums before), the script says so, suggests `rpm-ostree refresh-md --force`, and moves on. It doesn't retry in a loop.

### Reboot

A layered package is only usable after you reboot into the new deployment. The summary prints `Reboot required to use layered packages: ghostty` when that applies. **The script never reboots.** Run `systemctl reboot` when it suits you.

### git identity and credentials

The dotfiles `.gitconfig` carries the shared git settings and includes `~/.gitconfig.local` for machine-local ones. Before an existing `~/.gitconfig` is backed up to make way for it, the script copies its `user.name`, `user.email`, `user.signingkey` and every `credential.*` entry into `~/.gitconfig.local`. Multi-valued keys keep all their values in order, including the empty `helper =` reset that gh writes. A key already in `~/.gitconfig.local` is never changed.

The copy is all or nothing. The new file is built in a temp file next to `~/.gitconfig.local`, from a copy of the existing file plus the missing keys. Every copied value is checked, and then the temp file is moved into place with mode 0600. If any step fails, `~/.gitconfig.local` is left as it was. `--dry-run` lists the key names it would copy, never their values.

The script refuses to migrate in these cases. It warns, leaves `~/.gitconfig` in place and doesn't stow the git package:

- `~/.gitconfig` uses `[include]` or `[includeIf]`. Flattening them would change which settings apply where.
- `~/.gitconfig.local` is a symlink or not a regular file. The script never writes through it.
- A key it would copy has no value (a bare key). `git config` can't write one exactly.
- Either file can't be read.

In each case, move the settings into `~/.gitconfig.local` by hand and re-run.

`git config --global` is only used when the dotfiles git package was not stowed and neither `~/.gitconfig` nor `~/.config/git/config` resolves into the dotfiles repo, because otherwise it would write into the repo. The identity is checked last, after `~/.laptop.local` runs, from the final `~/.gitconfig` with its includes. If `user.name` or `user.email` is missing or empty, the summary warns you.

The font counts as installed when `~/.local/share/fonts/JetBrainsMono/` has `.ttf` files, or when `fc-list` lists "JetBrainsMono Nerd". Only then is the download skipped.

### Shell

zsh comes from Homebrew, and the login shell stays bash: no `chsh`, no `usermod`. Ghostty starts zsh through its `command =` setting, which lives in the dotfiles Ghostty config (for example `command = /home/linuxbrew/.linuxbrew/bin/zsh`). If that line is missing, the script warns you.

## Personal additions

Create `~/.laptop.local` before running. The script sources it at the end (under `--dry-run` it only says it would). Use it for anything personal: identity, private repo clones, bin symlinks.

```bash
# ~/.laptop.local

# git identity goes in ~/.gitconfig.local, which the stowed dotfiles
# .gitconfig includes. Not --global: ~/.gitconfig is a link into the repo.
git config --file ~/.gitconfig.local user.name  "Your Name"
git config --file ~/.gitconfig.local user.email "you@example.com"

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

`tests/run.sh` is a plain-bash harness that installs nothing. The script runs under `env -i` with an allowlisted environment: sandbox `PATH`, `HOME`, `XDG_*`, `HOMEBREW_*` and `FNM_*`; no host `MISE_*`, exported functions or `BASH_ENV`/`ENV`. A guard refuses to start if any path it passes (including every `LAPTOP_BREW_DIRS` entry) is outside the sandbox once symlinks are resolved. It runs `linux` with a throwaway `HOME` and a `PATH` of logging stubs (brew, rpm-ostree, stow, mise, apt-get, sudo, …). The mise stub models mise's side effects on disk: state/cache dirs on every run, the global config, versioned installs with the prefix/alias links, and shims that only `mise reshim` creates. Each shim logs its call and runs the pinned version's tool. `mise install` is a no-op for a version that is already installed. npm's global install puts `claude` in Node's `bin` directory without a shim. Any mise call during a dry run therefore changes the `HOME` snapshot. The `npm` on `PATH` is a stub that fails, so the tests prove that Claude Code goes through mise's shim. The tests cover:

- platform detection;
- the `--dry-run` plan on Bazzite and Pop!_OS, including checks that nothing was executed, mise was never run, and `HOME` is unchanged;
- conflict backups and the bling-line warning, and hand-made links into the repo (no data loss, conflict reported);
- stubbed real runs on Bazzite and Pop!_OS, each followed by a re-run, to confirm idempotence (mise installed once, Node pinned once, config unchanged);
- mise config parsing, each with dry-run and real runs that assert no `mise use` and a byte-identical config: `["tools"]` + `node = "20"`, `[tools]` + `node.version = "20"`, and a multiline string containing a fake `[tools]` header. Invalid TOML, no python3 and no `tomllib` are all treated as uncertain;
- mise edge cases: a pin matching no installed version (pin 20, only 22 installed), a non-executable `node`, missing shims restored only by `mise reshim` (and a failing reshim), no `installs/node/lts` link (reconciled on every run), `[tools.node]` tables, unparsed pins (never re-pinned), the reshim that exposes `claude`, `node` outside `[tools]`, a leftover fnm, a global config that resolves into the repo or can't be resolved, and a failing mise, with Claude Code skipped and no `npm` used when Node isn't ready;
- apt key download or dearmor failures on Pop!_OS;
- sandbox guards, including brew prefixes and `HOME` that escape the sandbox through a symlink;
- an rpm-ostree failure.

CI (`.github/workflows/ci.yml`) runs both commands on every push and pull request.
