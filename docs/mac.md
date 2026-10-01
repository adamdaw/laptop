# Mac setup

There is no automated Mac setup script yet. `linux` doesn't support macOS,
and nothing in this repository changes a Mac for you. What exists is [`mac/Brewfile`](../mac/Brewfile), a list of Homebrew
packages, and this page of steps to run by hand.

None of this has been run on a Mac. The Brewfile's names were checked against
Homebrew's package index, and the tests check its syntax and that it covers
the tools `linux` installs. Whether `brew bundle` succeeds on a given Mac is
untested.

## The Brewfile

It is curated by hand, not a dump of one machine. The first sections are what
the dotfiles need, matching what `linux` installs on Bazzite from Homebrew.
The last section, "Optional", is personal extras that nothing depends on.

It deliberately leaves out anything tied to an employer, and it has no `node`
formula: Node comes from mise, as on Linux.

Install [Homebrew](https://brew.sh) first, then from a clone of this
repository:

```bash
brew bundle check --verbose --file=mac/Brewfile   # what is missing or outdated; changes nothing
brew bundle install --file=mac/Brewfile           # install what is missing
```

- `brew bundle check` exits 0 when everything in the file is installed and up
  to date, and non-zero otherwise. `--verbose` lists what is unmet.
- `brew bundle install` installs what is missing and **upgrades** anything in
  the file that is outdated. Add `--no-upgrade` to install only what is
  missing. Packages already installed and current are left alone.
- Both read `./Brewfile` unless `--file` is given, so keep the `--file`.

### What `brew bundle cleanup` would do

`brew bundle cleanup --file=mac/Brewfile` uninstalls everything Homebrew
installed that is **not** listed in the file. It prompts before removing
anything.

Be careful with it on a machine this file doesn't fully describe. The Brewfile
leaves out work tools on purpose, so on a work Mac cleanup would offer to
remove them. When cleanup goes ahead it also resets Homebrew's trust store to
what the file declares, and this file declares none, so every tap, formula or
cask you trusted by hand would lose that trust.

`--force` skips the prompt and removes everything straight away. Don't pass it
unless you have just read the list the prompt would have shown and want all of
it gone.

## After `brew bundle`

These are the steps `linux` does on Linux that the Brewfile can't.

1. **Node, through mise.** `mise use -g node@lts`. Don't install Node from
   Homebrew or fnm.
2. **npm tools**, under that Node:

   ```bash
   npm install -g @anthropic-ai/claude-code @openai/codex @earendil-works/pi-coding-agent
   npm install -g @salesforce/cli @salesforce/lwc-language-server   # Salesforce work only
   sf plugins install code-analyzer                                  # needs the JDK below
   ```

3. **Java 21.** `openjdk@21` is keg-only: Homebrew doesn't link it into its
   prefix. The dotfiles' bash and zsh configuration finds it under the keg and
   sets `JAVA_HOME`, so no `sudo ln -s` is needed for the shells. If
   `openjdk@17` is still installed from before, it can go once 21 works
   (`brew uninstall openjdk@17`).
4. **GitHub.** `gh auth login`, before cloning anything private.
5. **Dotfiles**, below.

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
| `bin`, `agy`, `claude`, `render-url` | `stow --no-folding -t "$HOME" <package>`, so `~/bin`, `~/.config/agy`, `~/.claude` and `~/.local/share/render-url` stay real directories and nothing written there lands in the repository |
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
- Node LTS through mise, then the agent CLIs and the Salesforce tools;
- clone the dotfiles, back up conflicts (never `--adopt`), carry the git
  identity into `~/.gitconfig.local`, and stow the packages in the table
  above, skipping `applications` and `xdg`;
- link atuin's config;
- source `~/.laptop.local` for personal additions.

It would live at `mac/setup`, next to the Brewfile. It isn't written because
the Brewfile plus the steps above cover most of the value, and a script that
changes a work machine needs testing on one first.
