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
| `-n`, `--dry-run` | Print every command that would run (installs, backups, stow, git config). Read-only checks (`brew list`, `rpm -q`, `rpm-ostree status`, `fc-list`, `dpkg -s`, `voxtype --version`, `nvim --version`) still run so the plan is accurate. `mise` is never executed during a dry run on either platform, not even `mise --version`, because mise creates state and cache directories whenever it runs. Whether mise and Node are already installed is read from disk instead: mise on `PATH` or in `~/.local/bin`, the `node` pin in mise's global config (parsed as TOML with python3's `tomllib`), an executable `node` installed under mise's data dir that matches that pin, and mise's `node`/`npm` shims. Nothing is changed. |
| `--print-os` | Print the detected platform (`debian` or `atomic`) and exit |
| `-h`, `--help` | Usage |

## What it installs

| Category | Ubuntu / Pop!_OS (apt unless noted) | Bazzite (Homebrew unless noted) |
|---|---|---|
| Shell | zsh, zsh-autosuggestions, zsh-syntax-highlighting, Starship (installer) | zsh, zsh-autosuggestions, zsh-syntax-highlighting, starship |
| Core | git, git-delta, curl, gpg, wget, build-essential, stow | git, git-delta, wget, stow (skipped when the image already has them) |
| Terminal | Neovim 0.12.5 (verified upstream release, `~/.local`; apt's older neovim stays as `/usr/bin/nvim`), tmux, xclip, Ghostty (ghostty-ubuntu installer) | neovim, tmux (image), Ghostty (**rpm-ostree**, Terra) |
| Search | ripgrep, fd-find, fzf, bat | ripgrep, fd, fzf, bat |
| Data | jq | jq |
| GitHub | gh CLI (GitHub apt repo) | gh |
| Node | mise (mise's apt repo) + Node LTS; Claude Code, Codex, pi and pnpm under it | mise + Node LTS; Claude Code, Codex, pi and pnpm under it |
| Java | openjdk-21-jdk | openjdk@21 (keg-only) |
| Python | uv (installer) | uv |
| JavaScript runtime | Bun (installer, `~/.bun`) | Bun (installer, `~/.bun`) |
| Font | JetBrains Mono Nerd Font (`~/.local/share/fonts`) | checked; installed to `~/.local/share/fonts` only if missing |
| Dev tools | shellcheck | lazygit, tree-sitter-cli, shellcheck, markdownlint-cli2, gitleaks |
| Shell history | — (install atuin yourself) | atuin |
| render-url | npm dependencies + Playwright Chromium (mise's Node) | npm dependencies + Playwright Chromium (mise's Node) |
| Speech-to-text | voxtype (verified release binary, `~/.local/bin`) + large-v3-turbo model; ffmpeg | voxtype (verified release binary, `~/.local/bin`) + large-v3-turbo model; ffmpeg (image, else Homebrew) |

On Bazzite, a Homebrew formula is skipped when the command is already on `PATH` from the image (for example `tmux` and `git`). lazygit, tree-sitter-cli and markdownlint-cli2 are installed on Bazzite only; Ubuntu 24.04's apt has no suitable packages for them, so install them yourself there if you need them. gitleaks is also Bazzite-only: the dotfiles pre-commit hook needs 8.20.0 or newer, and Ubuntu 24.04's package is 8.16.0. Without a new enough gitleaks the hook skips the scan with a warning. Homebrew's gitleaks is installed even if another gitleaks is on `PATH`, since that one may be too old.

### render-url

The dotfiles `render-url` package stows a headless-Chromium URL renderer into `~/.local/share/render-url`. Its npm dependencies (Playwright) are not in the repo, so after stowing the script installs them there, on both platforms, with the commands dotfiles' `bin/render-url` documents, run through mise's Node:

```bash
cd ~/.local/share/render-url && mise exec -- npm ci && mise exec -- npx playwright install chromium
```

- `npm ci` runs only when `node_modules` is missing or `package-lock.json` changed since the last install (its SHA-256 is recorded in `node_modules/.laptop-package-lock.sha256` only after `npm ci` succeeds, and `npm ci` wipes it).
- `npx playwright install chromium` runs on every run. The script doesn't guess from the browser cache: only Playwright knows the exact builds it needs (Chromium and the headless shell, at its pinned revision). It skips the ones it already has, so a re-run costs only a quick check, and an old, partial or failed browser install is fixed by the next run.
- An earlier stow with folding (`~/.local/share/render-url` as a link into the repo) is unfolded by `stow --restow --no-folding`. If the directory still resolves into the dotfiles repo after stowing, or there's no usable mise-managed Node, the step is skipped with a warning, so npm never writes into the repo. A failed `npm ci` or browser install is a warning too, and the next run retries it.
- `--dry-run` only prints these commands.

### voxtype

The dotfiles `transcribe` wrapper converts audio with ffmpeg and transcribes it with [voxtype](https://github.com/peteonrails/voxtype). On both platforms the script installs voxtype's standalone release binary, pinned to one version (`VOXTYPE_VERSION` in the script, currently 1.1.0), as `~/.local/bin/voxtype` (mode 755).

- **Build.** `voxtype-<version>-linux-x86_64-vulkan` when a Vulkan loader is present (`libvulkan.so.1` in `ldconfig -p` or in the usual library directories). Otherwise the CPU build that matches `/proc/cpuinfo`: `avx512` if it lists `avx512f`, else `avx2`, else `baseline`. Only x86_64 is handled; any other architecture gets a warning and no voxtype.
- **Verified before it is installed, two ways.** The release's `SHA256SUMS.txt` must carry a valid GPG signature (`SHA256SUMS.txt.asc`) made by the pinned key `9CCF7915B750CAE8B095ED1AA3FC9F33FD209279`, which is fetched from keys.openpgp.org by that fingerprint, and the binary must hash to what `SHA256SUMS.txt` lists for it (the copy that is hashed is the one that is installed). gpg runs with a temporary `GNUPGHOME` that is removed afterwards, so your keyring is neither read nor changed, and with `--no-autostart`, so no gpg-agent is left behind. The signature is checked before the binary is downloaded. If either check fails, a download fails, or gpg isn't installed, the script warns, installs nothing and carries on; the next run tries again.
- **When.** Only if `~/.local/bin/voxtype` is missing or `voxtype --version` isn't the pinned version. The new binary is written next to the old one and renamed over it. Anything there that isn't a regular file (a symlink to your own build, say) is left alone with a warning. That is checked before the downloads and again just before the rename, so a link that appears while the release is downloading is kept too.
- **Model.** If `~/.local/share/voxtype/models/ggml-large-v3-turbo.bin` is missing, the script runs `voxtype setup --download --model large-v3-turbo --no-post-install --quiet`. That is a download of about 1.6 GB, and the script says so first. Only the file's presence is checked, not its size or content: an unfinished download that voxtype left under another name (`.part`) is retried, but a damaged file with the model's own name counts as downloaded, so delete it to have it fetched again. `LAPTOP_SKIP_VOXTYPE_MODEL=1` skips the model and the config change below; the binary is still installed.
- **Config.** `voxtype setup` writes a default `~/.config/voxtype/config.toml` whose model is `base.en`, which `transcribe` would then use. Once the model is in place, a line that is exactly the generated `model = "base.en"` is changed to `model = "large-v3-turbo"`. Any other model line is yours and is never changed, nor is a config that is a symlink or resolves into the dotfiles repo. To keep the generated `base.en` line on purpose, run with `LAPTOP_SKIP_VOXTYPE_MODEL=1`.
- **ffmpeg.** If no `ffmpeg` is on `PATH`, it is installed with apt on Ubuntu/Pop!_OS and with Homebrew on Bazzite (whose image ships `/usr/bin/ffmpeg`, so normally nothing happens there).
- `--dry-run` prints the plan (which build, both verifications, the model download and its size, the config change) and downloads nothing. It does run `voxtype --version` on an installed binary, which writes nothing.

### Neovim on Ubuntu / Pop!_OS

The dotfiles Neovim config needs Neovim 0.12 or newer: the `nvim-treesitter` revision its `lazy-lock.json` pins (the `main` branch) requires 0.12. apt's is older (0.9.5 on Ubuntu 24.04, which Pop!_OS 24.04 is built on) and cannot load that config. So on the apt path the script also installs the upstream release, pinned to one version (`NEOVIM_VERSION` in the script, currently 0.12.5; the minimum is `NEOVIM_MIN`, 0.12.0). Bazzite is unchanged: its Neovim comes from Homebrew.

- **When.** The script takes the first `nvim` on the `PATH` it is run with and reads its version from `nvim --version`. If that is 0.12.0 or newer, nothing is downloaded, unpacked or linked, whatever `~/.local/bin` holds. Versions are compared number by number, so 0.9.5 is older than 0.12.0. A version that can't be read (no `NVIM vX.Y.Z` first line, or `nvim --version` fails) counts as too old, and the run says so.
- **What.** `nvim-linux-x86_64.tar.gz` from the pinned GitHub release, unpacked into `~/.local/share/laptop/nvim-<version>` and linked as `~/.local/bin/nvim`. Only x86_64 is handled; any other architecture gets a warning and keeps apt's nvim. apt's `neovim` package is still installed and left alone: it is what `root` and `sudo` get, and the fallback if the release can't be installed.
- **Verification.** Neovim publishes no signed checksum file, so the tarball's SHA256 is a literal in the script (`NEOVIM_SHA256`) next to the version; change both together. Nothing in the environment changes it. A tarball with any other hash is not unpacked. The tree is unpacked next to its destination and checked to report the pinned version. Then a marker file holding that SHA256 (`.laptop-verified-sha256`) is written into it, and it is renamed into place, so the marker and the complete tree appear together.
- **An existing tree.** `~/.local/share/laptop/nvim-<version>` is only used when it is a real directory whose marker names the pinned SHA256, which is how this script leaves it. Any other tree there (no marker, another hash, a symlink) is never run, not even to read its version, and never linked. It is moved to the backup directory with a warning, and the release is installed fresh. The marker says who unpacked the tree, not that nobody has changed it since.
- **Which `nvim` runs, and what the script claims.** It only reports what it can see:
  - On the `PATH` of the run: when `~/.local/bin` is on it, an older `nvim` ahead of it is a warning that names it, and `nvim is now 0.12.5 … on this run's PATH` is printed only when that is what `nvim` resolves to. When `~/.local/bin` is not on it (a fresh machine: a login session's `PATH` is made at login), nothing is claimed. The summary then says in one line that this could not be checked, and to run `nvim --version` after logging out and in.
  - Where mise is active: the dotfiles `.bashrc` and `.zshrc` activate mise after they put `~/bin` and `~/.local/bin` first, so an `nvim` that mise has installed comes before `~/.local/bin/nvim` in those shells. If mise has an `nvim` under its data directory that is older than 0.12.0, or whose version can't be read, that is a warning naming it. This is read from disk: mise and its shims are never run. When mise's shim is the first `nvim` on `PATH` and every `nvim` mise has installed is new enough, the step does nothing.
  - Not checked: other sessions. The dotfiles `.bashrc` and `.zshrc` return at once in a non-interactive shell, and dotfiles stows no `.profile`, `.bash_profile`, `.zprofile` or `.zshenv`. Ubuntu's default `~/.profile` adds `~/.local/bin` (when it exists at login), but only sh and bash login shells read it. This script makes zsh the login shell, zsh does not read `~/.profile`, and Ubuntu's `/etc/zsh` files add no `~/.local/bin`. So a non-interactive zsh session has `~/.local/bin` on `PATH` only if it inherits it.
- **Conflicts.** An existing `~/.local/bin/nvim` that is first on `PATH` and too old is replaced by the link: a regular file is moved to the backup directory first, like any other conflict.
- **Failures.** A failed download, a hash mismatch or a tarball that doesn't unpack is a warning; the run continues, nothing is installed, and the next run retries. The warning is repeated in the summary and names the `nvim` that is still in use.
- **Upgrades.** A newer `NEOVIM_VERSION` is only installed on a machine whose first `nvim` on `PATH` is older than `NEOVIM_MIN`. Elsewhere, remove `~/.local/bin/nvim` and re-run. Old `nvim-<version>` trees are not removed.
- `--dry-run` prints the plan (the move of an unverified tree, download, verification, unpack, link) and the same warnings, and downloads nothing. It does run `nvim --version`, with `NVIM_LOG_FILE=/dev/null`, since Neovim otherwise creates `~/.local/state/nvim/nvim.log` even for that.

### Java 21

JDK 21 supports the Salesforce Apex language server and Code Analyzer. Bazzite
installs Homebrew `openjdk@21`, checking the formula even when a different `java`
is on PATH. Ubuntu/Pop!_OS installs `openjdk-21-jdk` through the existing apt
package checks. Both appear in `--dry-run` and are skipped once installed.
The dotfiles bash/zsh configuration selects the keg-only JDK via `JAVA_HOME`.
There is no macOS installer or Brewfile in this repository; on the Mac run
`brew install openjdk@21` (the dotfiles still accept 17 during the upgrade).

### Node comes from mise

[mise](https://mise.jdx.dev) manages Node; the dotfiles already activate it in bash and zsh. mise is installed from the first source in the install-order rule: the Homebrew formula on Bazzite, and mise's official apt repo (`mise.jdx.dev/deb`, signed with mise's key) on Ubuntu/Pop!_OS. The key is dearmored into a temp file and installed with mode 0644, and the sources file is made 0644, so both are always readable by apt. If the key download or the dearmor fails, the run stops before any repo is added, and no empty keyring is left behind. The apt repo was chosen over the `mise.run` installer because apt verifies signatures and `apt-get upgrade` keeps mise current, the same way the gh repo works. A mise that is already on `PATH` or in `~/.local/bin` (where `mise.run` puts it) is used as is.

Node LTS is installed with `mise use -g node@lts`. **That writes `~/.config/mise/config.toml`** (mise's global config; `MISE_GLOBAL_CONFIG_FILE` / `MISE_CONFIG_DIR` / `XDG_CONFIG_HOME` move it). The dotfiles don't manage that file today. If a dotfiles `mise` package takes it over later, pin Node there. The script never writes the file when its path resolves into the dotfiles repo, or when that path can't be resolved; it warns instead.

The global config is parsed as real TOML with python3's standard-library `tomllib` (Python 3.11+, which Bazzite and Ubuntu 24.04 ship). No hand-written parser is involved, so every valid form of a pin counts: `[tools]` / `["tools"]` tables, `node.version = "…"`, `[tools.node]`, inline tables, `core:node`, and multiline strings that happen to contain a `[tools]` line. There are three outcomes:

- **No file, or no `tools.node` entry:** node is not pinned, so `mise use -g node@lts` may pin it.
- **A `tools.node` entry, in any form:** node is pinned, and **the pin is never changed.** When the entry is one version string (directly or as `version = "…"`), that version is used to check what is installed.
- **Uncertain:** python3 or `tomllib` is missing, or the file can't be read or parsed. The config is never written and Node isn't installed. The script warns you to fix the file, or to pin node yourself, and then re-run.

Node counts as installed only when an **executable** `node` exists for the pinned version: `installs/node/<pin>` (a version, or the prefix/alias links mise makes, such as `22` or `lts`), or `installs/node/<pin>.*` for a numeric prefix. mise's `node`/`npm` shims must exist too. If the disk can't prove that, the script *reconciles*: it runs `mise install node` and then `mise reshim`, and never changes the pin. Examples are a pin of `20` with only 22 installed, a pin whose version isn't a single string (such as a list), or missing shims. Each command has its own warning if it fails.

**Reconciling can repeat, and it isn't free.** Take a pin of `lts`: it is proven only by the `installs/node/lts` link, which mise makes when an alias matches an installed version. If that link isn't there, **every run** reconciles again. `mise install node` then has to resolve what `lts` means today, which can hit the network (mise's version index). If a newer LTS is out, it installs that version too. So a re-run isn't guaranteed to be a no-op. The config is still never changed.

The agent CLIs (`@anthropic-ai/claude-code`, `@openai/codex`, `@earendil-works/pi-coding-agent`) are installed with Node LTS's own npm (`mise exec node@lts -- npm install -g …`), and only once mise's Node is known to work. Node LTS is used whatever node mise's global config pins, and the pin is never changed. So a machine pinned to, say, `node = "20"` still gets the CLIs under `installs/node/lts`, where they are checked for and linked from. Each is installed only if its command (`claude`, `codex`, `pi`) is missing from `~/.local/share/mise/installs/node/lts/bin`. That check reads the disk, so a dry run plans exactly what a real run would do. pnpm is enabled with `mise exec node@lts -- corepack enable pnpm`. Before the first of these `mise exec node@lts` installs, the script prints a note that mise may download and install Node LTS first. mise does that when its `lts` isn't installed or a newer LTS is out. Node 25 and later no longer ship corepack, so when Node LTS has none it is installed first with `npm install -g corepack`. corepack puts pnpm next to the first `corepack` on `PATH`, and `mise exec` puts Node's own `bin` directory first, so pnpm lands there and not among the shims. When something was installed, or a shim is missing, the script runs `mise reshim`.

Then `~/.local/bin` gets links. `claude`, `codex` and `pi` point straight at `…/installs/node/lts/bin/<tool>`, not at mise shims, because Omnigent starts them with a renamed `argv[0]` and mise's shims reject that. `pnpm` points straight at `…/installs/node/lts/bin/pnpm` too. The script enables it under Node LTS only, and a shim runs the tool of whatever node mise pins, which may have no pnpm. `node`, `npm`, `npx` and `corepack` point at `~/.local/share/mise/shims/<tool>`. Each of these is linked only if the tool is also in Node LTS's `bin` directory. A shim can outlive its tool, for example after `lts` moves to a new Node. An older `pnpm` link to its shim is a symlink, so it is retargeted, not backed up. An existing symlink there (right, wrong or dangling) is replaced. A regular file or directory is backed up like any other conflict, never overwritten. A link whose target is missing is skipped with a warning. So is the whole step when `~/.local/bin` resolves into the dotfiles repo. After Node LTS moves to a new major version, re-run the script to reinstall the CLIs under it; the `lts` links follow automatically. Every failure (an npm install, corepack, reshim, a link) is a warning, and the next run retries it. If Node isn't ready (the config is uncertain or the write was blocked, mise failed, or the shims are missing), the script skips the agent CLIs with a warning. It never falls back to another `npm` on `PATH`. The same applies to the npm `fund` setting.

fnm is no longer installed. An existing fnm (`~/.local/share/fnm`, or `fnm` on `PATH`) is left alone and only noted in the output. Remove it yourself when you no longer need it.

### Salesforce

Both Linux paths optionally install `@salesforce/cli` and
`@salesforce/lwc-language-server` through `mise exec -- npm install -g`,
then `mise reshim`, followed by `mise exec -- sf plugins install code-analyzer`
(Java 11+; the bootstrap installs JDK 21). Installed packages and Code Analyzer
are skipped independently. Failures warn and retry on the next run; unusable
mise Node skips this step. Dry-run prints the commands without running mise.

To update npm installations explicitly, run
`mise exec -- npm install -g @salesforce/cli@latest @salesforce/lwc-language-server@latest`
and `mise reshim`; use `mise exec -- sf plugins update` for plugins.
`sf update` does not update an npm-installed CLI. No install-script exemption or
global npm script policy is configured: the inspected scripts only check legacy
CLI conflicts, protobuf dependency versions, and Yarn/Corepack symlinks.

## What it configures

- git: `core.hooksPath`, delta pager, `pull.rebase`, `push.autoSetupRemote`, `init.defaultBranch=main` — identity goes in `~/.laptop.local`
- SSH: generates `~/.ssh/id_ed25519` if absent
- Dotfiles: clones your dotfiles repo and stows `agy applications atuin bash bat bin claude ghostty git nvim render-url ripgrep ssh starship tmux zsh` — update `DOTFILES_REPO` at the top of `linux` to point at yours. `agy`, `applications`, `atuin`, `bin`, `claude`, `render-url` (and `xdg`, see below) are stowed with `--no-folding`, so `~/.config/agy`, `~/.config/atuin`, `~/.config/atuin-ai-server`, `~/.config/containers/systemd`, `~/bin`, `~/.local/bin`, `~/.local/share/applications`, `~/.local/share/render-url`, `~/.claude` and `~/.claude/skills` stay real directories and nothing written there lands in the repo. On a machine stowed before `bin` and `agy` were added, `~/bin` and `~/.config/agy` are folded links into the repo; the next run's `stow --restow --no-folding` replaces each with a real directory of per-file links, with no backups. Any file an installer already wrote into `~/bin` through the fold is inside the repo (an untracked file in `bin/bin/`); stow links it back, and it stays there until you move it out. Absolute symlinks are the exception: stow refuses to unfold a package holding them (`source is an absolute symlink`). So before stowing a `--no-folding` package whose directory is still folded, the script moves every absolute symlink under that fold into the backup directory. It never deletes one. Each move is listed in the summary with a warning; move the link back into `~/bin` if you still need it. For `claude` that matters most: Claude Code keeps its sessions, credentials and history in `~/.claude`, so only `CLAUDE.md` and the `route-local` skill are links; an existing `~/.claude/CLAUDE.md` is backed up like any other conflict. `--dry-run` prints each package's stow command exactly as a real run would run it (with or without `--no-folding`), even before the repo is cloned.
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

The copy is all or nothing. The new file is built in a temp file next to `~/.gitconfig.local`, from a copy of the existing file plus the missing keys. Every copied value is checked, and then the temp file is moved into place with mode 0600. The rename never follows a link or goes into a directory, and the result is checked afterwards. If any step fails, including listing `~/.gitconfig`, `~/.gitconfig.local` is left as it was. A trap removes the temp file if the run is interrupted. `--dry-run` lists the key names it would copy, never their values.

The script refuses to migrate in these cases. It warns, leaves `~/.gitconfig` in place and doesn't stow the git package:

- `~/.gitconfig` uses `[include]` or `[includeIf]`. Flattening them would change which settings apply where.
- An existing `~/.gitconfig.local` uses `[include]` or `[includeIf]`. The script can't tell safely which keys it already has.
- `~/.gitconfig.local` is a symlink or not a regular file. The script never writes through it.
- A key it would copy has no value (a bare key). `git config` can't write one exactly.
- Either file can't be read.

In each case, move the settings into `~/.gitconfig.local` by hand and re-run.

`git config --global` is only used when the dotfiles git package was not stowed and neither `~/.gitconfig` nor `~/.config/git/config` resolves into the dotfiles repo, because otherwise it would write into the repo. The identity is checked last, after `~/.laptop.local` runs, from the final `~/.config/git/config` and `~/.gitconfig` with their includes, in git's order. If `user.name` or `user.email` is missing or empty, the summary warns you.

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

`tests/run.sh` is a plain-bash harness that installs nothing. The script runs under `env -i` with an allowlisted environment: sandbox `PATH`, `HOME`, `XDG_*`, `HOMEBREW_*` and `FNM_*`; no host `MISE_*`, exported functions or `BASH_ENV`/`ENV`. A guard refuses to start if any path it passes (including every `LAPTOP_BREW_DIRS` and `LAPTOP_LIB_DIRS` entry, and `LAPTOP_CPUINFO`) is outside the sandbox once symlinks are resolved, so the host's Homebrew, CPU flags and Vulkan loader are never consulted. It runs `linux` with a throwaway `HOME` and a `PATH` of logging stubs (brew, rpm-ostree, stow, mise, apt-get, sudo, …). The mise stub models mise's side effects on disk: state/cache dirs on every run, the global config, versioned installs with the prefix/alias links, and shims that only `mise reshim` creates. Each shim logs its call and runs the pinned version's tool. `mise install` is a no-op for a version that is already installed. npm's global install puts `claude`, `codex` or `pi` in Node's `bin` directory without a shim, and `corepack enable pnpm` puts `pnpm` next to the `corepack` that ran. Any mise call during a dry run therefore changes the `HOME` snapshot. The `npm` on `PATH` is a stub that fails, so the tests prove that the agent CLIs go through mise's shim. The tests cover:

- platform detection;
- the `--dry-run` plan on Bazzite and Pop!_OS, including checks that nothing was executed, mise was never run, and `HOME` is unchanged;
- conflict backups and the bling-line warning, and hand-made links into the repo (no data loss, conflict reported);
- stubbed real runs on Bazzite and Pop!_OS, each followed by a re-run, to confirm idempotence (mise installed once, Node pinned once, config unchanged);
- mise config parsing, each with dry-run and real runs that assert no `mise use` and a byte-identical config: `["tools"]` + `node = "20"`, `[tools]` + `node.version = "20"`, and a multiline string containing a fake `[tools]` header. Invalid TOML, no python3 and no `tomllib` are all treated as uncertain;
- mise edge cases: a pin matching no installed version (pin 20, only 22 installed), a non-executable `node`, missing shims restored only by `mise reshim` (and a failing reshim), no `installs/node/lts` link (reconciled on every run; the agent CLIs are skipped with a warning, since they are linked from there), `[tools.node]` tables, unparsed pins (never re-pinned), the reshim that exposes `claude`, `node` outside `[tools]`, a leftover fnm, a global config that resolves into the repo or can't be resolved, and a failing mise, with the agent CLIs skipped and no `npm` used when Node isn't ready;
- apt key download or dearmor failures on Pop!_OS;
- render-url: `npm ci` and `playwright install chromium` through `mise exec` (the stubbed `mise exec` runs the pinned Node's own npm/npx; the stub npx models Playwright's pinned revision and downloads only missing builds). Covered: `npm ci` skipped on re-run while Playwright is still asked, `npm ci` again after a lockfile change, an older cached Chromium, a missing headless shell, a failed browser install retried on the next run, no usable Node, a failing `npm ci` (retried next run), a fold unfolded by `--restow --no-folding` (the stow stub models that), a link still into the repo after stowing, a missing package, and the `--no-folding` stows of `render-url` and `applications`;
- the claude package on both platforms: a fresh `HOME` gets real `~/.claude` and `~/.claude/skills` directories with only the package's files linked, existing `~/.claude` content is left alone, an existing `CLAUDE.md` is backed up (never adopted), and a dry run changes nothing;
- the stow commands a dry run prints (with the repo cloned or not) match the real run's, per package;
- the atuin package on both platforms: atuin's generated `config.toml` is backed up and replaced by the stowed link (never adopted), `~/.config/atuin`, `~/.config/atuin-ai-server` and `~/.config/containers/systemd` stay real directories with other units and podman's config untouched, the start hint shows only when podman is present, and nothing is enabled or started;
- absolute symlinks written into a folded `~/bin` (dangling and valid), moved to the backup dir before the unfold. This runs against the stow stub, and against GNU Stow itself when one is found in `/usr/bin` or `/bin` or named by `LAPTOP_TEST_REAL_STOW` (skipped otherwise). A control shows real stow refusing the unfold without the move. Nothing is moved when `~/bin` is a real directory, or a link to some other directory in the repo;
- `bin` and `agy` on both platforms: fresh runs give real `~/bin` and `~/.config/agy` directories, and a machine where both are folded links into the repo is unfolded by the restow, with no backups and new files kept out of the repo;
- agent CLIs on both platforms: installs through Node LTS's npm (`mise exec node@lts`, after one note that Node LTS may be downloaded), `corepack enable pnpm` through it too, reshim, the eight `~/.local/bin` links (dry-run plan, real run, idempotent re-run), an existing regular file (backed up), dangling and foreign links (replaced), a failing npm install (retried next run, its link skipped), a failing corepack, a Node LTS without corepack (installed from npm, and a failing install of it), a pin other than `lts` (`node = "20"`: still installed and linked under Node LTS, pin unchanged, and `~/.local/bin/pnpm` and `claude` actually run), an old `pnpm` link to its shim (retargeted), `lts` moved to a new Node with stale shims, a pnpm shim without pnpm in Node LTS, and `~/.local/bin` folded into the repo;
- `STOW_PACKAGES` matches the dotfiles repo's top-level package directories (a list in the tests; `xdg` is left out on purpose because it is only stowed on Bazzite GNOME). Set `LAPTOP_TEST_DOTFILES_DIR` to a dotfiles checkout to compare that list with the checkout as well. Otherwise that check is skipped, so the tests need no network;
- voxtype on both platforms, with fake `curl`, `gpg`, `uname` and `voxtype` (the fake gpg accepts a signature only for the exact `SHA256SUMS.txt` it was made for; `sha256sum` is the real one, hashing the fake release). Covered: a fresh install (pinned URLs, signature checked before the binary is downloaded, temporary `GNUPGHOME`, mode 755, no temp files left) and a no-op re-run, an older version upgraded, a symlink or directory at `~/.local/bin/voxtype` left alone (also one that appears while the release is downloading, on a fresh install and on an upgrade), a staged copy that differs from the download (refused), a non-x86_64 machine, each build choice (Vulkan through a library directory or `ldconfig`, avx512, avx2, baseline), a checksum mismatch (also on an upgrade: the old binary stays), a build missing from `SHA256SUMS.txt`, a bad signature (`SHA256SUMS.txt` rewritten to match a replaced binary, so only the signature can catch it), a good signature by another key, no gpg, failed downloads, the model present or missing, a failed model download retried on the next run (also when it left a `.part` file), a truncated model file counted as present, hand-edited model lines kept byte-identical, `LAPTOP_SKIP_VOXTYPE_MODEL=1`, ffmpeg present or missing, and dry runs that leave `HOME` unchanged and run no curl or gpg. Nothing touches the real `~/.local/bin` or `~/.config/voxtype`;
- Neovim on Pop!_OS, with a fake `nvim` standing in for apt's and a fake release tarball served by the `curl` stub (`tar`, `gzip` and `sha256sum` are the real ones). The script takes the tarball's SHA256 from one literal line, so the tests run a copy of `linux` with only that line set to the fake tarball's hash; `linux` itself is also run, with and without `LAPTOP_NEOVIM_SHA256` in the environment, to show it refuses the fake. Covered: apt's 0.9.5 with `~/.local/bin` not on `PATH` (unpacked, marked, linked, no readiness claimed, one plain line in the summary) and with it ahead (reported as ready on that `PATH`), no-op re-runs, no nvim at all, an nvim first on `PATH` that is already new enough (nothing downloaded or written, also with an older one in `~/.local/bin`), versions that only a numeric comparison gets right (0.9.5, 0.2.2; also 0.10.4 and 0.11.6), unreadable versions (counted as too old, and said so), an old regular file at `~/.local/bin/nvim` (backed up), a missing link repaired without a download, an unverified tree where the release goes (no marker, a marker for another hash, a symlinked marker, a symlink: never run, moved to the backup directory, installed fresh), an older or unreadable `nvim` ahead of `~/.local/bin` on the run's `PATH` (a warning naming it), an older or unreadable `nvim` that mise has installed and mise's shim first on `PATH` (never run), a failed download retried on the next run, a hash mismatch, a tarball holding another version, something that isn't a tarball, a non-x86_64 machine, `~/.local/bin` folded into the repo, dry runs that leave `HOME` unchanged, one on a machine with no dotfiles clone yet (the fake nvim, like the real one, creates `~/.local/state/nvim` unless `NVIM_LOG_FILE` is set) and run no curl, and Bazzite, where none of this runs;
- sandbox guards, including brew prefixes and `HOME` that escape the sandbox through a symlink;
- an rpm-ostree failure.

CI (`.github/workflows/ci.yml`) runs both commands on every push and pull request.

## Atuin

The `atuin` package is stowed with `--no-folding`. atuin, podman and other Quadlet units write into `~/.config/atuin`, `~/.config/atuin-ai-server` and `~/.config/containers/systemd`, so those stay real directories. atuin writes its own default `~/.config/atuin/config.toml` the first time it runs. That regular file is backed up to the timestamped backup directory like any other conflict, and the stowed config replaces it.

The Homebrew `atuin` formula is installed on Bazzite. On Ubuntu/Pop!_OS, install atuin yourself if you want it; the config is stowed either way.

The script never enables or starts the `atuin-ai-server` Quadlet unit. When podman is present, the summary prints `systemctl --user daemon-reload && systemctl --user start atuin-ai-server` to run yourself. atuin-ai-server needs llama-swap listening on `:8080`, with a model that supports tool calling. See the dotfiles README's Atuin section.

## Ghostty as the Bazzite GNOME default

On Bazzite, with `GNOME` in `XDG_CURRENT_DESKTOP` and `ghostty` on PATH,
the bootstrap also stows dotfiles' `xdg` package using `--no-folding`.
Update your dotfiles checkout to include that package first. An existing
`~/.config/xdg-terminals.list` is backed up through the normal conflict
handling, even when it already contains `com.mitchellh.ghostty.desktop`.
This selects Ghostty for `xdg-terminal-exec`; shared config directories stay
real directories.

The bootstrap finds the GNOME custom shortcut bound to `<Control><Alt>t`
and changes its command to `ghostty --gtk-single-instance=true`. If none
exists, it appends a Terminal shortcut at an unused custom path, preserving
other shortcuts. Re-runs leave an already correct shortcut alone.
Missing GNOME/gsettings schemas or Ghostty produce a skip notice; when
Ghostty is only layered for the next boot, re-run after reboot. Debian and
other Atomic desktops are unaffected. `--dry-run` reports stow, backup and
shortcut changes without writing them. Tests use a stateful fake gsettings
inside the existing guarded temporary HOME sandbox, never the host settings.
