# Mac setup

There is no automated Mac setup script yet. `linux` doesn't support macOS,
and nothing in this repository changes a Mac for you. What exists is [`mac/Brewfile`](../mac/Brewfile), a list of Homebrew
packages, and this page of steps to run by hand.

None of this has been run on a Mac. The Brewfile's names were checked against
Homebrew's package index (and, for the two third-party taps, against the tap
repositories on GitHub), and the tests check its syntax and that it covers
the tools `linux` installs. Whether `brew bundle` succeeds on a given Mac is
untested.

## The Brewfile

It is curated by hand, not a dump of one machine. The first sections are what
the dotfiles need, matching what `linux` installs on Bazzite from Homebrew.
The two "Optional" sections at the end are extras that nothing depends on:
delete or comment out any of those lines freely.

It has no `node` formula: Node comes from mise, as on Linux.

### Third-party taps

Everything comes from Homebrew's own repositories except two entries in the
last section:

- `schpet/tap/linear`, a command-line client for linear.app, from
  [schpet/homebrew-tap](https://github.com/schpet/homebrew-tap);
- `deskflow/tap/deskflow`, keyboard and mouse sharing, from
  [deskflow/homebrew-tap](https://github.com/deskflow/homebrew-tap).

A tap's formulae and casks are Ruby code that Homebrew runs as you, and nobody
at Homebrew reviews these two. Since Homebrew 6.0.0 it refuses to load anything
from a non-official tap until that tap or item is
[trusted](https://docs.brew.sh/Tap-Trust). The two entries carry
`trusted: true`, so `brew bundle install` trusts exactly those two items (not
the rest of either tap) before installing them, without a prompt or a separate
`brew trust`. Running `brew bundle install` on this file therefore means
accepting those two taps' code. If you don't, delete their four lines first.

### Tailscale

`brew "tailscale"` is the Homebrew formula: the open-source `tailscale` CLI
and `tailscaled` daemon. It is listed because that is what the Mac uses today.
Tailscale for macOS also comes as an App Store app and as a standalone app
from tailscale.com, and those are separate installs that this file doesn't
manage. Use one variant, not several: drop the line on a Mac that has
Tailscale from the App Store or the standalone app.

Install [Homebrew](https://brew.sh) first, then from a clone of this
repository:

```bash
brew bundle check --verbose --file=mac/Brewfile   # what is missing or outdated; changes nothing
brew bundle install --file=mac/Brewfile           # install what is missing
```

- `brew bundle check` exits 0 when everything in the file is installed and up
  to date, and non-zero otherwise. `--verbose` lists what is unmet.
- `brew bundle install` installs what is missing and **upgrades** anything in
  the file that is outdated. With `--no-upgrade` it doesn't run `brew upgrade`
  on outdated entries, but they may still be upgraded when installing
  something else needs it. Packages already installed and current are left
  alone.
- Both read `./Brewfile` unless `--file` is given, so keep the `--file`.

### What `brew bundle cleanup` would do

`brew bundle cleanup --file=mac/Brewfile` uninstalls everything Homebrew
installed that is **not** listed in the file. It prompts before removing
anything.

Be careful with it on a machine this file doesn't fully describe. The Brewfile
isn't a dump of any one Mac, so on a work Mac cleanup would offer to remove
whatever else is installed there. When cleanup goes ahead it also resets
Homebrew's trust store to what the file declares, and this file declares only
`schpet/tap/linear` and `deskflow/tap/deskflow`, so every other tap, formula
or cask you trusted by hand would lose that trust.

`--force` skips the prompt and removes everything straight away. Don't pass it
unless you have just read the list the prompt would have shown and want all of
it gone.

## After `brew bundle`

These are the steps `linux` does on Linux that the Brewfile can't. They mirror
what `linux` runs; none has been tried on macOS.

### Node: mise's, never Homebrew's

The dotfiles `mise` package is mise's global config, and it pins Node LTS.
Stow the dotfiles first, `mise` included and with `--no-folding` (see
[Stowing the dotfiles on macOS](#stowing-the-dotfiles-on-macos)), then
install the Node it pins:

```bash
mise install
```

Don't run `mise use -g node@lts` first: it writes a `~/.config/mise/config.toml`
of its own, which then conflicts with the package's.

Homebrew installs its own `node` anyway, as a dependency of
`markdownlint-cli2`. That one must not be used for anything below: a bare
`npm` on a Mac whose shells aren't set up yet is likely to be Homebrew's, and
its global packages land in Homebrew's prefix, not under mise. So every
command here goes through `mise exec node@lts --`, which puts mise's Node LTS
first on `PATH` for that one command, whatever the shell has activated.

### npm tools

```bash
mise exec node@lts -- npm install -g @anthropic-ai/claude-code @openai/codex @earendil-works/pi-coding-agent
mise exec node@lts -- corepack enable pnpm
mise reshim
```

Node 25 and later no longer ship corepack. If
`~/.local/share/mise/installs/node/lts/bin/corepack` doesn't exist, install
it first, with the same Node, and then run the `corepack enable pnpm` line:

```bash
mise exec node@lts -- npm install -g corepack
```

Salesforce work only (the plugin needs the JDK below):

```bash
mise exec node@lts -- npm install -g @salesforce/cli @salesforce/lwc-language-server
mise reshim
mise exec node@lts -- sf plugins install code-analyzer
```

### Links in `~/.local/bin`

`claude`, `codex` and `pi` must be linked **directly** to Node LTS's bin
directory, not to mise's shims. Omnigent starts them with a renamed
`argv[0]`, and a mise shim picks its tool from `argv[0]`, so it rejects the
call. `pnpm` is linked the same way. `node`, `npm`, `npx` and `corepack` link
to the shims.

```bash
lts=~/.local/share/mise/installs/node/lts/bin    # mise's default data dir
ls "$lts/claude" "$lts/codex" "$lts/pi" "$lts/pnpm"   # all four must exist first
mkdir -p ~/.local/bin
for tool in claude codex pi pnpm; do ln -s "$lts/$tool" ~/.local/bin/$tool; done
for tool in node npm npx corepack; do ln -s ~/.local/share/mise/shims/$tool ~/.local/bin/$tool; done
```

`ln -s` refuses to replace a file that is already there; look at what it is
before removing it. If `MISE_DATA_DIR` or `XDG_DATA_HOME` is set, mise's
directory is elsewhere. When mise moves to a new Node LTS, `lts` points at an
install without the three tools: run the first `npm install -g` line again.

### Java 21

`openjdk@21` is keg-only: Homebrew doesn't link it into its prefix. The
dotfiles' bash and zsh configuration finds it under the keg and sets
`JAVA_HOME`, so no `sudo ln -s` is needed for the shells. If `openjdk@17` is
still installed from before, it can go once 21 works
(`brew uninstall openjdk@17`).

### GitHub, then the dotfiles

`gh auth login`, before cloning anything private. Then stow the dotfiles
(next section) and install render-url's dependencies (the one after).

## Stowing the dotfiles on macOS

Clone the [dotfiles](https://github.com/adamdaw/dotfiles) to
`~/Projects/Home/dotfiles` and run everything from there. Always pass
`-t "$HOME"`.

`linux` backs up conflicting files for you. On the Mac you do it by hand, one
package at a time: preview with `-n`, move whatever conflicts out of the way,
then stow. Never use `stow --adopt`, which overwrites the repository's files
with the machine's.

```bash
cd ~/Projects/Home/dotfiles
stow -n -v -t "$HOME" zsh      # preview: lists links and any conflicts
# move each conflicting file to a backup directory, then:
stow -t "$HOME" zsh
```

| Package | On macOS |
|---|---|
| `bash`, `zsh`, `tmux`, `ghostty`, `starship`, `nvim`, `ripgrep`, `bat` | `stow -t "$HOME" <package>` |
| `bin`, `agy`, `claude`, `mise`, `render-url` | `stow --no-folding -t "$HOME" <package>`, so `~/bin`, `~/.config/agy`, `~/.claude`, `~/.config/mise` and `~/.local/share/render-url` stay real directories and nothing written there lands in the repository |
| `git` | Before moving an existing `~/.gitconfig` away, copy its `user.name`, `user.email`, `user.signingkey` and `credential.*` settings into `~/.gitconfig.local`, which the dotfiles `.gitconfig` includes. Then stow. |
| `ssh` | An existing `~/.ssh/config` conflicts. Read it before moving it: it may hold hosts the dotfiles one doesn't have. |
| `atuin` | Link the one file that matters. See below. |
| `applications`, `xdg` | **Skip.** Linux only: a `.desktop` launcher and the XDG default-terminal list. Harmless if stowed, but unused. |

After stowing `agy`, run `agy-permissions-apply --dry-run`, review, then run
it without `--dry-run`.

### atuin, file by file

The `atuin` package also carries the Atuin AI server's config and a podman
Quadlet unit, which are Linux only. On the Mac only atuin's own config is
useful. atuin writes a default `config.toml` the first time it runs, so set
that aside first:

```bash
cfg=~/.config/atuin/config.toml
if [ -f "$cfg" ] && [ ! -L "$cfg" ]; then
    mv -n "$cfg" "$cfg.generated-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p ~/.config/atuin
ln -s ~/Projects/Home/dotfiles/atuin/.config/atuin/config.toml "$cfg"
```

History search (`Ctrl+R`) then works. `?` (Atuin AI) fails with a connection
error on the Mac, because the server it talks to isn't set up there.

## render-url

`bin/render-url` exits with an error until Playwright is installed next to
the stowed files. After `stow --no-folding -t "$HOME" render-url`:

```bash
ls -ld ~/.local/share/render-url    # must be a real directory, not a link into the dotfiles
cd ~/.local/share/render-url
mise exec node@lts -- npm ci
mise exec node@lts -- npx playwright install chromium
```

If that directory is a link into the dotfiles repository, stop: npm would
write `node_modules` into the repository. Unstow the package and stow it
again with `--no-folding`. Run `npm ci` again whenever `package-lock.json`
changes. The Chromium download goes to Playwright's own cache; where that is
on macOS, and whether this Chromium runs there, is untested.

## remote-status

`remote-status` needs `timeout` and `getent`, and macOS ships neither.

- `timeout` comes from Homebrew's `coreutils`, which is in the Brewfile. It
  is always installed as `gtimeout`. The formula also links commands macOS
  doesn't provide under their plain names, so `timeout` should be on `PATH`
  too. That is read from the formula, not seen on a Mac. If it isn't there,
  add `$(brew --prefix)/opt/coreutils/libexec/gnubin` to `PATH`, which holds
  every command under its plain name.
- `getent` has no Homebrew formula for macOS. Nothing in the Brewfile
  provides it, so `remote-status` stops at its tool check on the Mac until
  the script itself handles macOS. `remote-sync` and `macc` don't use it.

## voxtype and transcribe

The dotfiles `transcribe` script needs `ffmpeg` and `voxtype`. ffmpeg is in
the Brewfile. voxtype is not: Homebrew has no formula or cask for it.

`linux` installs voxtype's Linux x86_64 release binary and verifies its signed
checksums. That code doesn't apply to macOS. The pinned release (1.1.0) does
publish a `macos-universal` binary and a `.dmg`, with a separate
`SHA256SUMS-macos.txt`, but no signature for either was published alongside
them, and nobody has tried them here. So on the Mac `transcribe` is
unsupported until someone installs voxtype by hand, puts it on `PATH` (or
sets `VOXTYPE` to its path), and downloads a model with
`voxtype setup --download --model large-v3-turbo`.

## What a future `mac/setup` script would do

Roughly what `linux` does, for macOS, with the same `--dry-run`:

- check for Homebrew, then `brew bundle install --file=mac/Brewfile`;
- clone the dotfiles, back up conflicts (never `--adopt`), carry the git
  identity into `~/.gitconfig.local`, and stow the packages in the table
  above, skipping `applications` and `xdg`;
- Node LTS through mise (pinned by the stowed `mise` package), then the agent
  CLIs, their `~/.local/bin` links and the Salesforce tools;
- link atuin's config, and install render-url's dependencies;
- source `~/.laptop.local` for personal additions.

It would live at `mac/setup`, next to the Brewfile. It isn't written because
the Brewfile plus the steps above cover most of the value, and a script that
changes a work machine needs testing on one first.
