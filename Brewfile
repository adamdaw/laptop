# Brewfile — macOS package manifest, applied by the `mac` script via `brew bundle`.
#
# macOS ONLY. The Linux path (`./linux`) uses apt and never reads this file,
# so brew can't run on Linux by construction. Keep this in sync with the
# equivalent apt packages in `linux`.
#
# Generated from `brew bundle dump` on the 2026-07-15 restore, then extended
# to match the full `linux` toolset (neovim, jq, ripgrep, fd, fzf, bat, uv,
# the Nerd Font, …). Prune anything you don't want on a fresh machine.

# ── Taps ─────────────────────────────────────────────────────────────────────
tap "schpet/tap"

# ── Core CLI ─────────────────────────────────────────────────────────────────
brew "git"
brew "git-delta"                 # syntax-highlighting pager (linux: git-delta)
brew "stow"                      # dotfiles symlink manager
brew "wget"
brew "jq"
brew "ripgrep"
brew "fd"                        # linux: fd-find
brew "fzf"
brew "bat"
brew "neovim"

# ── Shell ────────────────────────────────────────────────────────────────────
brew "zsh"
brew "zsh-autosuggestions"
brew "zsh-syntax-highlighting"
brew "starship"                  # prompt
brew "zoxide"                    # smarter cd
brew "eza"                       # modern ls

# ── Dev / runtimes ───────────────────────────────────────────────────────────
brew "gh"                        # GitHub CLI
brew "fnm"                       # Node version manager
brew "mise"                      # polyglot runtime manager
brew "node"                      # baseline node; fnm/mise still manage per-project
                                 #   versions. See the node/fnm/mise reconciliation
                                 #   note in the laptop-dotfiles project context.
brew "bun"                       # JS runtime / bundler
brew "uv"                        # Python package manager
brew "schpet/tap/linear", trusted: true

# ── Fonts ────────────────────────────────────────────────────────────────────
cask "font-jetbrains-mono-nerd-font"

# ── GUI apps ─────────────────────────────────────────────────────────────────
cask "ghostty"                   # terminal
cask "claude-code"               # Claude Code (linux installs via npm)
cask "1password-cli"
cask "markdown-preview"
cask "slack"
