#!/usr/bin/env bash
# Plain-bash tests for ./linux: platform detection, the --dry-run plan, and a
# stubbed "real" run (backups instead of --adopt, idempotent re-run).
#
# Nothing real is installed: every external command the script can call is a
# stub that logs its arguments, and PATH holds only those stubs plus a sandbox
# of core utilities. HOME is a throwaway directory. The script runs under
# `env -i` with an allowlisted environment (see sandboxed), so exported shell
# functions, BASH_ENV/ENV and host HOMEBREW_*/MISE_*/FNM_*/XDG_* settings never reach it.
#
# Usage: tests/run.sh

# Stub bodies are single-quoted on purpose: they expand when the stub runs.
# shellcheck disable=SC2016

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/linux"
PASS=0
FAIL=0
CURRENT=""

# Core utilities the script (and the stubs) legitimately need.
CORE_UTILS=(bash env cat grep sed find realpath dirname basename date mkdir mv cp rm ln chmod head tr sort mktemp touch readlink ls wc python3)

ALL_FORMULAE=(git git-delta stow neovim tmux jq ripgrep fd fzf bat wget gh starship zsh zsh-autosuggestions zsh-syntax-highlighting uv mise)
ALL_PACKAGES=(agy bash bat bin ghostty git nvim ripgrep ssh starship tmux zsh)

# Calls that would change the machine. None may appear during --dry-run.
MUTATING='^(sudo|apt-get|chsh|usermod|ujust|ssh-keygen|npm|curl|stow|systemctl|ubuntu-report|unzip|fc-cache)( |$)|^brew install|^rpm-ostree (install|upgrade|reboot)|^flatpak install|^git (clone|config)|^mise (use|install)'

# rpm-ostree status --json shapes. Deployments are listed newest first:
# staged/pending, then booted, then rollback.
BOOTED_ONLY='{"deployments":[{"booted":true,"requested-packages":[],"packages":[]}]}'
PENDING_GHOSTTY='{"deployments":[{"booted":false,"staged":true,"requested-packages":["ghostty"],"packages":["ghostty"]},{"booted":true,"requested-packages":[]}]}'
ROLLBACK_GHOSTTY='{"deployments":[{"booted":true,"requested-packages":[],"packages":[]},{"booted":false,"requested-packages":["ghostty"],"packages":["ghostty"]}]}'

# A mise that models its filesystem side effects. Like real mise, every
# invocation leaves state and cache dirs behind; `use -g node@lts` writes the
# global config and installs node (plus shims); `install node` installs only.
# It resolves its dirs from the same MISE_*/XDG_* variables as real mise.
MISE_SIDE_EFFECTS='
data="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}"
conf="${MISE_GLOBAL_CONFIG_FILE:-${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}/config.toml}"
mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/mise" "${XDG_CACHE_HOME:-$HOME/.cache}/mise"
install_node() {
  mkdir -p "$data/installs/node/22.12.0/bin" "$data/shims"
  printf "#!/bin/sh\necho v22.12.0\n" > "$data/installs/node/22.12.0/bin/node"
  chmod +x "$data/installs/node/22.12.0/bin/node"
  ln -sfn 22.12.0 "$data/installs/node/lts"
  touch "$data/shims/node" "$data/shims/npm" # not executable: the npm stub still answers
}
case "$*" in
  --version)        echo "2026.9.0 linux-x64 (stub)" ;;
  "use -g node@lts") mkdir -p "${conf%/*}"; printf "[tools]\nnode = \"lts\"\n" >> "$conf"; install_node ;;
  "install node")   install_node ;;
  *)                echo "stub mise: unexpected: $*" >&2; exit 2 ;;
esac'

# ── Assertions ───────────────────────────────────────────────────────────────

pass() { PASS=$((PASS + 1)); printf "  ok   %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  FAIL %s\n" "$1"; }

check() { # check "description" command...
  local desc="$1"; shift
  if "$@"; then pass "$CURRENT: $desc"; else fail "$CURRENT: $desc"; fi
}

has()      { grep -qE -- "$2" <<<"$1"; }
is_real_dir() { [ -d "$1" ] && [ ! -L "$1" ]; }
lacks()    { ! grep -qE -- "$2" <<<"$1"; }
log_has()  { grep -qE -- "$1" "$LOG"; }
log_lacks(){ ! grep -qE -- "$1" "$LOG"; }
log_count(){ grep -cE -- "$1" "$LOG" || true; }

# ── Sandbox ──────────────────────────────────────────────────────────────────

stub() { # stub NAME [BODY] — BODY runs after the call is logged
  cat > "$STUBS/$1" <<EOF
#!$SANDBOX/sysbin/bash
printf '%s\n' "$1 \$*" >> "\$STUB_LOG"
${2:-exit 0}
EOF
  chmod +x "$STUBS/$1"
}

os_release() { # os_release ID [ID_LIKE] [VARIANT_ID]
  { echo "ID=$1"; [ -n "${2:-}" ] && echo "ID_LIKE=\"$2\""; [ -n "${3:-}" ] && echo "VARIANT_ID=$3"; } > "$SANDBOX/os-release"
  export LAPTOP_OS_RELEASE="$SANDBOX/os-release"
}

ostree_booted() { touch "$SANDBOX/ostree-booted"; }

setup() { # setup TEST_NAME
  CURRENT="$1"
  SANDBOX="$(mktemp -d)"
  STUBS="$SANDBOX/stubs"
  STATE="$SANDBOX/state"
  LOG="$SANDBOX/calls.log"
  export HOME="$SANDBOX/home" STUB_LOG="$LOG" STUB_STATE="$STATE"
  export LAPTOP_OSTREE_BOOTED="$SANDBOX/ostree-booted"
  export LAPTOP_YUM_REPOS_DIR="$SANDBOX/yum.repos.d"
  # Never let the script find the host's Homebrew by its well-known paths.
  export LAPTOP_BREW_DIRS="$SANDBOX/linuxbrew"
  export LAPTOP_OS_RELEASE="$SANDBOX/os-release"
  mkdir -p "$STUBS" "$STATE" "$SANDBOX/sysbin" "$HOME" "$LAPTOP_YUM_REPOS_DIR"
  : > "$LOG"
  : > "$STATE/brew-installed"
  : > "$STATE/rpm-installed"
  echo "$BOOTED_ONLY" > "$STATE/ostree-status"
  touch "$LAPTOP_YUM_REPOS_DIR/terra.repo"

  SANDBOX_REAL="$(realpath "$SANDBOX")"
  mkdir -p "$SANDBOX/tmp"
  # Resolve core utilities from the system dirs only, never from Homebrew.
  local u path
  for u in "${CORE_UTILS[@]}"; do
    path="$(PATH=/usr/bin:/bin type -P "$u")" || { echo "missing core utility: $u" >&2; exit 2; }
    ln -s "$path" "$SANDBOX/sysbin/$u"
  done

  # mise is absent until something installs it: `brew install mise` or
  # `sudo apt-get install -y mise` puts this stub on PATH.
  stub mise "$MISE_SIDE_EFFECTS"; mv "$STUBS/mise" "$STATE/mise-stub"
  # Like `sudo tee` / `sudo dd`, read piped input, so the writer never gets SIGPIPE.
  stub sudo '[ -p /dev/stdin ] && cat > /dev/null
[ "$*" = "apt-get install -y mise" ] && cp "$STUB_STATE/mise-stub" "${0%/*}/mise"; exit 0'
  stub apt-get; stub chsh; stub usermod; stub ujust; stub flatpak
  stub systemctl; stub npm; stub unzip; stub fc-cache
  stub sh '[ -p /dev/stdin ] && cat > /dev/null; exit 0' # `curl ... | sh` installers
  stub curl 'exit "${STUB_CURL_RC:-0}"' 
  stub dpkg '[ "$1" = --print-architecture ] && echo amd64 || exit 1'
  stub gpg
  stub fc-list 'echo "/x/JetBrainsMonoNerdFont-Regular.ttf: JetBrainsMono Nerd Font:style=Regular"'
  stub git 'if [ "$1" = clone ]; then mkdir -p "$3/.git"; fi'
  stub ssh-keygen 'while [ $# -gt 0 ]; do [ "$1" = -f ] && { touch "$2" "$2.pub"; break; }; shift; done'
  stub brew '
case "$1" in
  list)     grep -qx -- "${!#}" "$STUB_STATE/brew-installed" ;;
  install)  shift; printf "%s\n" "$@" >> "$STUB_STATE/brew-installed"
            for f; do [ "$f" = mise ] && cp "$STUB_STATE/mise-stub" "${0%/*}/mise"; done; exit 0 ;;
  --prefix) cd "$(dirname "$0")/.." && pwd ;;
  shellenv) p="$(cd "$(dirname "$0")/.." && pwd)"
            echo "export HOMEBREW_PREFIX=\"$p\"; export PATH=\"$p/bin:\$PATH\";" ;;
esac'
  stub rpm '[ "$1" = -q ] && grep -qx -- "$2" "$STUB_STATE/rpm-installed"'
  stub rpm-ostree '
case "$1" in
  status)  cat "$STUB_STATE/ostree-status" ;;
  install) [ "${STUB_OSTREE_RC:-0}" = 0 ] || { echo "error: Checksum mismatch (terra)" >&2; exit 1; }
           shift; pkgs=""; for p; do [ "$p" = --idempotent ] || pkgs="${pkgs:+$pkgs,}\"$p\""; done
           echo "{\"deployments\":[{\"staged\":true,\"booted\":false,\"requested-packages\":[$pkgs]},{\"booted\":true,\"requested-packages\":[]}]}" > "$STUB_STATE/ostree-status" ;;
esac'
  # A minimal stow that models folding: a directory missing from the target
  # becomes one symlink into the package; a folded link owned by another
  # package of the same stow dir is unfolded into a real directory. Like real
  # stow it never overwrites anything it does not own, and never writes into
  # the stow dir.
  stub stow '
dir="" target="" pkgs=()
for a; do
  case "$a" in
    --adopt)   echo "stub stow: --adopt is forbidden" >&2; exit 99 ;;
    --dir=*)   dir="${a#--dir=}" ;;
    --target=*) target="${a#--target=}" ;;
    -*) ;;
    *) pkgs+=("$a") ;;
  esac
done
repo="$(realpath "$dir")"
conflict() { echo "stub stow: conflict on $1" >&2; exit 1; }
same()  { [ "$(realpath "$1" 2>/dev/null)" = "$(realpath "$2")" ]; }
owned() { local r; r="$(realpath "$1" 2>/dev/null)" || return 1; [[ "$r" == "$repo"/* ]]; }
link_children() { # link_children REAL_DIR TARGET_DIR
  local c
  for c in "$1"/* "$1"/.[!.]*; do
    if [ -e "$c" ] || [ -L "$c" ]; then ln -s "$c" "$2/${c##*/}"; fi
  done
}
stow_dir() { # stow_dir SOURCE_DIR TARGET_DIR
  local s t n old
  for s in "$1"/* "$1"/.[!.]*; do
    [ -e "$s" ] || [ -L "$s" ] || continue
    n="${s##*/}"
    case "$n" in README*|LICENSE*|COPYING|.git|.gitignore|.stow-local-ignore) continue ;; esac
    t="$2/$n"
    if [ -d "$s" ] && [ ! -L "$s" ]; then
      if [ ! -e "$t" ] && [ ! -L "$t" ]; then ln -s "$s" "$t"          # fold
      elif [ -L "$t" ] && same "$t" "$s"; then :
      elif [ -L "$t" ] && [ -d "$t" ] && owned "$t"; then            # unfold
        old="$(realpath "$t")"; rm "$t"; mkdir "$t"; link_children "$old" "$t"; stow_dir "$s" "$t"
      elif [ -d "$t" ] && [ ! -L "$t" ]; then stow_dir "$s" "$t"
      else conflict "$t"; fi
    elif [ -L "$t" ] && same "$t" "$s"; then :
    elif [ -e "$t" ] || [ -L "$t" ]; then conflict "$t"
    else ln -s "$s" "$t"; fi
  done
}
for p in "${pkgs[@]}"; do stow_dir "$dir/$p" "$target"; done'
}

teardown() { rm -rf "$SANDBOX"; }

bazzite() { os_release bazzite fedora bazzite-gnome; ostree_booted; }

dotfiles_fixture() {
  local d="$HOME/Projects/Home/dotfiles" p
  mkdir -p "$d/.git"
  for p in "${ALL_PACKAGES[@]}"; do mkdir -p "$d/$p"; done
  echo "# dotfiles bashrc" > "$d/bash/.bashrc"
  echo "# dotfiles zshrc"  > "$d/zsh/.zshrc"
  echo "set -g mouse on"   > "$d/tmux/.tmux.conf"
  mkdir -p "$d/ghostty/.config/ghostty" "$d/nvim/.config/nvim" "$d/bin/bin" "$d/git/.config/git" \
           "$d/agy/.config/agy" "$d/bat/.config/bat" "$d/ssh/.ssh" "$d/starship/.config"
  echo "font-family = JetBrainsMono Nerd Font" > "$d/ghostty/.config/ghostty/config.ghostty"
  echo "-- init" > "$d/nvim/.config/nvim/init.lua"
  echo "#!/bin/sh" > "$d/bin/bin/hello"
  echo "[user]" > "$d/git/.gitconfig"
  echo "{}" > "$d/agy/.config/agy/permissions.json"
  echo "--theme=x" > "$d/bat/.config/bat/config"
  echo "Host *" > "$d/ssh/.ssh/config"
  echo "" > "$d/starship/.config/starship.toml"
  echo "--smart-case" > "$d/ripgrep/.ripgreprc"
  echo "README — must not be stowed" > "$d/bash/README.md"
}

# mise on PATH, node pinned in its global config and installed, as
# `mise use -g node@lts` leaves it. Made without running mise.
mise_node_fixture() {
  cp "$STATE/mise-stub" "$STUBS/mise"
  mkdir -p "$HOME/.config/mise" "$HOME/.local/share/mise/installs/node/22.12.0/bin"
  printf '[tools]\nnode = "lts"\n' > "$HOME/.config/mise/config.toml"
  touch "$HOME/.local/share/mise/installs/node/22.12.0/bin/node"
}

# Everything already in place, as after a successful run.
all_done_fixture() {
  printf "%s\n" "${ALL_FORMULAE[@]}" > "$STATE/brew-installed"
  echo ghostty > "$STATE/rpm-installed"
  mkdir -p "$HOME/.ssh" "$HOME/.bun/bin"
  touch "$HOME/.ssh/id_ed25519"
  printf '#!%s\necho 1.1.0\n' "$SANDBOX/sysbin/bash" > "$HOME/.bun/bin/bun"; chmod +x "$HOME/.bun/bin/bun"
  stub claude
  mise_node_fixture
  sandboxed "$STUBS/stow" --dir="$HOME/Projects/Home/dotfiles" --target="$HOME" --restow "${ALL_PACKAGES[@]}"
  : > "$LOG"
}

home_snapshot() {
  (cd "$HOME" && find . -printf '%p %y %s %l\n' | sort
   find . -type f -exec cat {} + 2>/dev/null)
}

repo_snapshot() {
  (cd "$HOME/Projects/Home/dotfiles" && find . -printf '%p %y %s %l\n' | sort
   find . -type f -exec cat {} + 2>/dev/null)
}

# True if $1 is a path inside the sandbox once canonicalised. Rejects any
# ".." component outright rather than trusting it to resolve inwards.
inside_sandbox() {
  case "/$1/" in */../*) return 1 ;; esac
  [ -n "$1" ] && [[ "$(realpath -m -- "$1")" == "$SANDBOX_REAL"/* ]]
}

# Every path the script is told about must be inside the sandbox.
guard_sandbox() {
  local entry n=0
  for entry in ${LAPTOP_BREW_DIRS:-}; do
    n=$((n + 1))
    inside_sandbox "$entry" || { echo "guard: LAPTOP_BREW_DIRS entry outside sandbox: $entry" >&2; return 1; }
  done
  [ "$n" -ge 1 ] || { echo "guard: LAPTOP_BREW_DIRS is empty" >&2; return 1; }
  for entry in "$HOME" "$LAPTOP_OS_RELEASE" "$LAPTOP_OSTREE_BOOTED" "$LAPTOP_YUM_REPOS_DIR" "$STUB_LOG" "$STUB_STATE"; do
    inside_sandbox "$entry" || { echo "guard: path outside sandbox: $entry" >&2; return 1; }
  done
}

# Run a command with only the allowlisted environment: no inherited
# variables, exported functions, BASH_ENV/ENV, or host tool settings.
sandboxed() {
  guard_sandbox || { echo "refusing to run outside the sandbox" >&2; exit 2; }
  local v
  local -a vars=(
    PATH="$STUBS:$SANDBOX/sysbin" HOME="$HOME" USER=tester LOGNAME=tester
    LANG=C.UTF-8 TERM=dumb SHELL=/bin/bash TMPDIR="$SANDBOX/tmp"
    XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
    XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
    HOMEBREW_PREFIX="$SANDBOX/homebrew-env" HOMEBREW_CELLAR="$SANDBOX/homebrew-env/Cellar"
    HOMEBREW_REPOSITORY="$SANDBOX/homebrew-env" HOMEBREW_NO_AUTO_UPDATE=1
    FNM_DIR="$HOME/.local/share/fnm"
    LAPTOP_OS_RELEASE="$LAPTOP_OS_RELEASE" LAPTOP_OSTREE_BOOTED="$LAPTOP_OSTREE_BOOTED"
    LAPTOP_YUM_REPOS_DIR="$LAPTOP_YUM_REPOS_DIR" LAPTOP_BREW_DIRS="$LAPTOP_BREW_DIRS"
    STUB_LOG="$STUB_LOG" STUB_STATE="$STUB_STATE"
  )
  for v in STUB_CURL_RC STUB_OSTREE_RC; do
    if [ -n "${!v:-}" ]; then vars+=("$v=${!v}"); fi
  done
  "$SANDBOX/sysbin/env" -i "${vars[@]}" "$@"
}

run_linux() { # run_linux ARGS... — sets OUT and RC
  guard_sandbox || { echo "refusing to run outside the sandbox" >&2; exit 2; }
  OUT="$(sandboxed "$SANDBOX/sysbin/bash" "$SCRIPT" "$@" 2>&1 </dev/null)"
  RC=$?
  # shellcheck disable=SC2001 # a regex, not a fixed string
  OUT="$(sed $'s/\x1b\\[[0-9;]*m//g' <<<"$OUT")" # drop colours
}

# ── Tests: platform detection ────────────────────────────────────────────────

detects() { # detects EXPECTED ID ID_LIKE VARIANT_ID OSTREE(0|1)
  setup "detect $2${4:+/$4}$([ "$5" = 1 ] && echo " +ostree")"
  os_release "$2" "$3" "$4"
  [ "$5" = 1 ] && ostree_booted
  run_linux --print-os
  check "=> $1" [ "$OUT" = "$1" ]
  teardown
}

test_detection() {
  detects atomic               bazzite "fedora"        bazzite-gnome 1
  detects atomic               bazzite "fedora"        bazzite-gnome 0
  detects atomic               fedora  ""              silverblue    1
  detects atomic               aurora  "fedora"        aurora-dx     1
  detects debian               ubuntu  "debian"        ""            0
  detects debian               pop     "ubuntu debian" ""            0
  detects debian               debian  ""              ""            0
  detects unsupported:fedora   fedora  ""              workstation   0
  detects unsupported:arch     arch    ""              ""            0

  setup "detect missing os-release"
  run_linux --print-os
  check "=> unsupported:unknown" [ "$OUT" = unsupported:unknown ]
  teardown

  setup "unsupported platform"
  os_release arch
  run_linux --dry-run
  check "exits non-zero" [ "$RC" -ne 0 ]
  check "explains why" has "$OUT" "unsupported platform \(arch\)"
  check "changes nothing" log_lacks "$MUTATING"
  teardown

  setup "unknown option"
  bazzite
  run_linux --bogus
  check "exits non-zero" [ "$RC" -ne 0 ]
  teardown
}

# ── Tests: Bazzite dry run ───────────────────────────────────────────────────

test_bazzite_dry_run_fresh() {
  setup "bazzite dry-run (fresh)"
  bazzite
  dotfiles_fixture
  stub tmux   # shipped by the image, not by brew
  printf 'export PS1=x\ntest -f /usr/share/ublue-os/bling/bling.sh && source /usr/share/ublue-os/bling/bling.sh\n' > "$HOME/.bashrc"
  echo "# distro zshrc" > "$HOME/.zshrc"
  local before; before="$(home_snapshot)"

  run_linux --dry-run
  local brew_line; brew_line="$(grep -F '[dry-run] brew install' <<<"$OUT")"

  check "exits 0" [ "$RC" -eq 0 ]
  check "detects Bazzite" has "$OUT" "Detected Bazzite"
  check "plans exactly one brew install" [ "$(grep -cF '[dry-run] brew install' <<<"$OUT")" -eq 1 ]
  local f
  for f in zsh zsh-autosuggestions zsh-syntax-highlighting git-delta neovim ripgrep fd fzf bat jq gh starship uv wget mise; do
    check "brew installs $f" has "$brew_line" " $f( |$)"
  done
  check "skips image-provided tmux" lacks "$brew_line" " tmux( |$)"
  check "reports tmux as system-provided" has "$OUT" "tmux provided by the system"
  check "layers only ghostty, in one transaction" has "$OUT" '\[dry-run\] rpm-ostree install --idempotent ghostty$'
  check "one rpm-ostree install" [ "$(grep -c 'rpm-ostree install' <<<"$OUT")" -eq 1 ]
  check "says a reboot is required" has "$OUT" "Reboot required.*ghostty"
  check "never reboots" lacks "$OUT" "\[dry-run\] (systemctl reboot|reboot|rpm-ostree .*--reboot)"
  check "stows tmux" has "$OUT" "\[dry-run\] stow .* --restow tmux$"
  check "stows every package" [ "$(grep -c '\[dry-run\] stow ' <<<"$OUT")" -eq "${#ALL_PACKAGES[@]}" ]
  check "never uses --adopt" lacks "$OUT" "--adopt"
  check "plans backup of conflicting ~/.bashrc" has "$OUT" "would back up ~/.bashrc"
  check "backup is timestamped" has "$OUT" "\[dry-run\] mv -n $HOME/.bashrc $HOME/.local/state/laptop/backups/[0-9]{8}-[0-9]{6}\.X{6}/.bashrc"
  check "warns about the bling line" has "$OUT" ".bashrc contains the 'ujust bazzite-cli' bling line"
  check "no bling warning for clean ~/.zshrc" lacks "$OUT" ".zshrc contains the"
  check "does not back up a stow-ignored README" lacks "$OUT" "README"
  check "warns ghostty config lacks command =" has "$OUT" "config.ghostty has no 'command =' line"
  check "keeps bash as login shell" has "$OUT" "login shell stays bash"
  check "no apt/sudo/chsh/ujust/flatpak in plan" lacks "$OUT" "\[dry-run\] (sudo|apt-get|chsh|usermod|ujust|flatpak)"
  check "no mutating command was executed" log_lacks "$MUTATING"
  check "mise is not run at all (it creates state)" log_lacks '^mise '
  check "plans node lts via mise" has "$OUT" "\[dry-run\] mise use -g node@lts$"
  check "no fnm anywhere in the plan" lacks "$OUT" "fnm"
  check "HOME is untouched" [ "$before" = "$(home_snapshot)" ]
  check "says nothing was changed" has "$OUT" "Dry run complete"
  teardown
}

test_bazzite_dry_run_all_done() {
  setup "bazzite dry-run (already set up)"
  bazzite
  dotfiles_fixture
  all_done_fixture
  local before; before="$(home_snapshot)"
  run_linux --dry-run
  check "exits 0" [ "$RC" -eq 0 ]
  check "HOME is untouched" [ "$before" = "$(home_snapshot)" ]
  check "no brew install" lacks "$OUT" "brew install"
  check "no rpm-ostree install" lacks "$OUT" "rpm-ostree install"
  check "ghostty already installed" has "$OUT" "ghostty already installed"
  check "no reboot needed" lacks "$OUT" "Reboot required"
  check "no backups" lacks "$OUT" "back up"
  check "no ssh-keygen" lacks "$OUT" "ssh-keygen"
  check "mise is not run; node found on disk" [ "$(log_count '^mise ')" -eq 0 ]
  check "reports node installed via mise" has "$OUT" 'node already installed via mise \(node = "lts" in '
  check "no mise use/install planned" lacks "$OUT" "\[dry-run\] mise "
  check "no mutating command was executed" log_lacks "$MUTATING"
  teardown
}

test_bazzite_dry_run_layered_pending() {
  setup "bazzite dry-run (ghostty layered, not rebooted)"
  bazzite
  dotfiles_fixture
  echo "$PENDING_GHOSTTY" > "$STATE/ostree-status"
  run_linux --dry-run
  check "does not layer again" lacks "$OUT" "rpm-ostree install"
  check "reports pending layer" has "$OUT" "ghostty already layered"
  check "still says reboot is required" has "$OUT" "Reboot required.*ghostty"
  teardown
}

test_bazzite_dry_run_no_terra() {
  setup "bazzite dry-run (no Terra repo)"
  bazzite
  dotfiles_fixture
  rm -f "$LAPTOP_YUM_REPOS_DIR"/terra*.repo
  run_linux --dry-run
  check "warns Terra is missing" has "$OUT" "Terra repo not found"
  teardown
}

test_bazzite_symlinked_dirs() {
  setup "bazzite dry-run (symlinked HOME / foreign dir link)"
  bazzite
  # Bazzite's /home is a symlink to /var/home, so HOME often is one too.
  mv "$HOME" "$SANDBOX/var-home"
  ln -s "$SANDBOX/var-home" "$HOME"
  dotfiles_fixture
  mkdir -p "$SANDBOX/elsewhere/nvim" "$HOME/.config"
  echo "-- not ours" > "$SANDBOX/elsewhere/nvim/init.lua"
  ln -s "$SANDBOX/elsewhere/nvim" "$HOME/.config/nvim"
  echo "# old tmux" > "$HOME/.tmux.conf"
  run_linux --dry-run
  check "exits 0" [ "$RC" -eq 0 ]
  check "symlinked HOME is not a conflict" lacks "$OUT" "$HOME/\.[a-z]+ is a symlink"
  check "still backs up real conflicts" has "$OUT" "would back up ~/.tmux.conf"
  check "refuses to move a file through a foreign dir link" has "$OUT" "\.config/nvim is a symlink to somewhere else"
  check "skips that package" has "$OUT" "skipped stowing nvim"
  check "does not plan stow for nvim" lacks "$OUT" "--restow nvim$"
  teardown
}

test_bazzite_rollback_only() {
  setup "bazzite dry-run (ghostty only in rollback)"
  bazzite
  dotfiles_fixture
  echo "$ROLLBACK_GHOSTTY" > "$STATE/ostree-status"
  run_linux --dry-run
  check "rollback does not count as installed" lacks "$OUT" "ghostty already (installed|layered)"
  check "plans layering ghostty" has "$OUT" '\[dry-run\] rpm-ostree install --idempotent ghostty$'
  teardown

  setup "bazzite dry-run (ghostty in booted deployment)"
  bazzite
  dotfiles_fixture
  echo '{"deployments":[{"booted":true,"requested-packages":["ghostty"]}]}' > "$STATE/ostree-status"
  run_linux --dry-run
  check "booted layer counts as installed" has "$OUT" "ghostty already installed"
  check "no rpm-ostree install" lacks "$OUT" "rpm-ostree install"
  check "no reboot needed" lacks "$OUT" "Reboot required"
  teardown

  setup "bazzite dry-run (no python3 to read status)"
  bazzite
  dotfiles_fixture
  rm "$SANDBOX/sysbin/python3"
  echo "$PENDING_GHOSTTY" > "$STATE/ostree-status"
  run_linux --dry-run
  check "falls back to an idempotent install" has "$OUT" '\[dry-run\] rpm-ostree install --idempotent ghostty$'
  teardown
}

test_bazzite_no_brew() {
  setup "bazzite dry-run (no Homebrew)"
  bazzite
  dotfiles_fixture
  rm "$STUBS/brew"
  run_linux --dry-run
  check "dry run does not stop" [ "$RC" -eq 0 ]
  check "warns Homebrew is missing" has "$OUT" "Homebrew not found — a real run stops here"
  check "still prints the brew plan" has "$OUT" "\[dry-run\] brew install git git-delta stow"
  check "reaches the end" has "$OUT" "Dry run complete"
  teardown

  setup "bazzite dry-run (brew not on PATH, found in its prefix)"
  bazzite
  dotfiles_fixture
  mkdir -p "$LAPTOP_BREW_DIRS/bin"
  mv "$STUBS/brew" "$LAPTOP_BREW_DIRS/bin/brew"
  echo git > "$STATE/brew-installed"
  run_linux --dry-run
  check "brew list answered via PATH" has "$OUT" "git already installed \(brew\)"
  check "loads brew shellenv from the prefix" log_has '^brew shellenv$'
  check "no Homebrew warning" lacks "$OUT" "Homebrew not found"
  check "shellenv PATH is applied (brew found on PATH)" log_has '^brew list'
  check "shellenv HOMEBREW_PREFIX is applied" has "$OUT" "command = $LAPTOP_BREW_DIRS/bin/zsh"
  teardown

  setup "bazzite run (no Homebrew)"
  bazzite
  dotfiles_fixture
  rm "$STUBS/brew"
  run_linux
  check "real run stops" [ "$RC" -ne 0 ]
  check "says why" has "$OUT" "error: Homebrew not found"
  check "changed nothing first" log_lacks "$MUTATING"
  teardown
}

test_backup_timestamp_collision() {
  setup "backups in the same second"
  bazzite
  dotfiles_fixture
  stub date 'echo 20260101-000000'   # every run gets the same timestamp
  echo "first bashrc" > "$HOME/.bashrc"
  run_linux
  rm "$HOME/.bashrc"
  echo "second bashrc" > "$HOME/.bashrc"
  run_linux
  local dirs
  dirs="$(find "$HOME/.local/state/laptop/backups" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  check "two runs get two backup dirs" [ "$dirs" -eq 2 ]
  check "first backup survives" [ "$(grep -rlx 'first bashrc' "$HOME/.local/state/laptop/backups" | wc -l)" -eq 1 ]
  check "second backup is kept too" [ "$(grep -rlx 'second bashrc' "$HOME/.local/state/laptop/backups" | wc -l)" -eq 1 ]
  check "dirs are named after the timestamp" [ "$(find "$HOME/.local/state/laptop/backups" -maxdepth 1 -name '20260101-000000.*' | wc -l)" -eq 2 ]
  teardown
}

test_backup_move_failure() {
  setup "backup move fails"
  bazzite
  dotfiles_fixture
  stub mv 'exit 1'
  echo "keep me" > "$HOME/.bashrc"
  run_linux
  check "run completes" [ "$RC" -eq 0 ]
  check "reports the failed move" has "$OUT" "could not move $HOME/.bashrc"
  check "skips stowing that package" has "$OUT" "skipped stowing bash"
  check "stow never ran for bash" log_lacks '^stow .* bash$'
  check "other packages still stowed" log_has '^stow .* zsh$'
  check "original file untouched" grep -qx "keep me" "$HOME/.bashrc"
  check "not listed as backed up" lacks "$OUT" "backed up ~/.bashrc"
  teardown
}

test_ancestor_file_conflict() {
  setup "file where the package needs a directory"
  bazzite
  dotfiles_fixture
  mkdir -p "$HOME/.config"
  echo "a file, not a dir" > "$HOME/.config/nvim"
  run_linux --dry-run
  check "dry run plans backing up the ancestor" has "$OUT" "would back up ~/.config/nvim \("
  check "only once" [ "$(grep -c 'would back up ~/.config/nvim ' <<<"$OUT")" -eq 1 ]
  check "does not try the file below it" lacks "$OUT" "init.lua"
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "ancestor file backed up" [ "$(grep -rlx 'a file, not a dir' "$HOME/.local/state/laptop/backups" | wc -l)" -eq 1 ]
  check "nvim is stowed" [ "$(realpath "$HOME/.config/nvim/init.lua")" = "$(realpath "$HOME/Projects/Home/dotfiles/nvim/.config/nvim/init.lua")" ]
  check "no stow failure" lacks "$OUT" "stow failed"
  teardown
}

test_run_sh_pipefail() {
  setup "failed download piped into a shell"
  bazzite
  dotfiles_fixture
  STUB_CURL_RC=22 run_linux   # curl fails, the `| bash` consumer succeeds
  check "run fails" [ "$RC" -ne 0 ]
  check "bun is not reported as installed" lacks "$OUT" "installed bun"
  check "curl was attempted" log_has '^curl -fsSL https://bun.sh/install'
  teardown
}

test_folded_into_other_package() {
  setup ".config folded into agy (other package)"
  bazzite
  dotfiles_fixture
  local d="$HOME/Projects/Home/dotfiles"
  ln -s Projects/Home/dotfiles/agy/.config "$HOME/.config"   # relative, as stow makes it
  local repo_before; repo_before="$(repo_snapshot)"
  run_linux --dry-run
  check "dry run: not treated as foreign" lacks "$OUT" "is a symlink to somewhere else"
  check "dry run: no package skipped" lacks "$OUT" "skipped stowing"
  check "dry run: nothing to back up" lacks "$OUT" "back up"
  check "dry run: bat planned" has "$OUT" "\[dry-run\] stow .* --restow bat$"
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "no package skipped" lacks "$OUT" "skipped stowing"
  check "no stow failure" lacks "$OUT" "stow failed"
  check "stow ran for bat" log_has '^stow .* bat$'
  check "bat config resolves into bat" [ "$(realpath "$HOME/.config/bat/config")" = "$(realpath "$d/bat/.config/bat/config")" ]
  check "agy config still resolves into agy" [ "$(realpath "$HOME/.config/agy/permissions.json")" = "$(realpath "$d/agy/.config/agy/permissions.json")" ]
  check ".config was unfolded into a real dir" is_real_dir "$HOME/.config"
  check "repo contents unchanged" [ "$repo_before" = "$(repo_snapshot)" ]
  check "mise config not written through the fold" [ ! -e "$d/agy/.config/mise" ]
  check "mise was not asked to pin node" log_lacks '^mise use'
  check "says why node was not pinned" has "$OUT" "mise's global config .* resolves into the dotfiles repo; not writing to it"
  check "no backups made" [ ! -e "$HOME/.local/state/laptop/backups" ]
  teardown
}

# The in_repo predicate is repository membership, not proof of a stow fold.
# A link made by hand into the repo must never lose data: the script leaves it
# (and the repo) alone, and stow reports the clash.
test_hand_made_repo_links() {
  setup "hand-made file link into the repo (not a fold)"
  bazzite
  dotfiles_fixture
  local d="$HOME/Projects/Home/dotfiles"
  ln -s "$d/bash/.bashrc" "$HOME/.tmux.conf"   # points at the wrong package's file
  local repo_before; repo_before="$(repo_snapshot)"
  run_linux --dry-run
  check "dry run: not backed up" lacks "$OUT" "back up ~/.tmux.conf"
  check "dry run: not called foreign" lacks "$OUT" "is a symlink to somewhere else"
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "stow reports the conflict" has "$OUT" "stub stow: conflict on $HOME/.tmux.conf"
  check "the package is reported as failed" has "$OUT" "stow failed for tmux"
  check "the hand-made link is untouched" [ "$(readlink "$HOME/.tmux.conf")" = "$d/bash/.bashrc" ]
  check "repo contents unchanged" [ "$repo_before" = "$(repo_snapshot)" ]
  check "nothing backed up" [ ! -e "$HOME/.local/state/laptop/backups" ]
  check "other packages still stowed" [ "$(realpath "$HOME/.zshrc")" = "$(realpath "$d/zsh/.zshrc")" ]
  teardown

  setup "hand-made dir link into the repo (not a fold)"
  bazzite
  dotfiles_fixture
  d="$HOME/Projects/Home/dotfiles"
  mkdir -p "$HOME/.config"
  ln -s "$d/agy/.config/agy" "$HOME/.config/nvim"   # nvim's dir, pointed into agy
  repo_before="$(repo_snapshot)"
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "nothing inside the repo was moved" [ "$repo_before" = "$(repo_snapshot)" ]
  check "agy's file still in the repo" grep -qx "{}" "$d/agy/.config/agy/permissions.json"
  check "nothing backed up" [ ! -e "$HOME/.local/state/laptop/backups" ]
  check "no package skipped" lacks "$OUT" "skipped stowing"
  check "stow unfolded it into a real dir" is_real_dir "$HOME/.config/nvim"
  check "nvim resolves into nvim" [ "$(realpath "$HOME/.config/nvim/init.lua")" = "$(realpath "$d/nvim/.config/nvim/init.lua")" ]
  teardown
}

test_isolation_sentinels() {
  setup "exported brew function cannot bypass stubs"
  bazzite
  dotfiles_fixture
  # If isolation failed, these would run instead of the stubs; they only
  # write a sentinel file, so a failure here is harmless.
  eval "brew() { echo exported-function >> '$SANDBOX/bypass'; }"
  export -f brew
  run_linux --dry-run
  unset -f brew
  check "exported function never ran" [ ! -e "$SANDBOX/bypass" ]
  check "the brew stub ran instead" log_has '^brew list'
  teardown

  setup "BASH_ENV / ENV cannot bypass stubs"
  bazzite
  dotfiles_fixture
  printf 'echo sourced >> %q\nbrew() { echo bash-env >> %q; }\n' "$SANDBOX/bypass" "$SANDBOX/bypass" > "$SANDBOX/startup.sh"
  BASH_ENV="$SANDBOX/startup.sh" ENV="$SANDBOX/startup.sh" run_linux --dry-run
  check "startup file never sourced" [ ! -e "$SANDBOX/bypass" ]
  check "the brew stub ran instead" log_has '^brew list'
  teardown

  setup "host tool settings do not leak"
  bazzite
  dotfiles_fixture
  HOMEBREW_PREFIX=/home/linuxbrew/.linuxbrew FNM_DIR=/nonexistent/fnm XDG_DATA_HOME=/nonexistent \
    MISE_DATA_DIR=/nonexistent/mise MISE_CONFIG_DIR=/nonexistent/mise MISE_GLOBAL_CONFIG_FILE=/nonexistent/mise.toml \
    run_linux --dry-run
  check "HOMEBREW_PREFIX is the sandbox one" has "$OUT" "command = $SANDBOX/homebrew-env/bin/zsh"
  check "no host prefix in output" lacks "$OUT" "/home/linuxbrew"
  check "no host MISE_*/XDG_* paths in output" lacks "$OUT" "/nonexistent"
  teardown

  setup "guard rejects paths outside the sandbox"
  bazzite
  local bad
  for bad in "/home/linuxbrew/.linuxbrew" "$SANDBOX/linuxbrew /home/linuxbrew/.linuxbrew" \
             "$SANDBOX/../escape" "$SANDBOX/linuxbrew $HOME/../../x" ""; do
    ( LAPTOP_BREW_DIRS="$bad"; guard_sandbox 2>/dev/null )
    check "rejects LAPTOP_BREW_DIRS='${bad//$SANDBOX/<sandbox>}'" [ $? -ne 0 ]
  done
  # Paths that look inside the sandbox but resolve outside it through a link.
  ln -s /home/linuxbrew/.linuxbrew "$SANDBOX/escape-abs"
  ln -s ../.. "$SANDBOX/escape-rel"
  for bad in "$SANDBOX/escape-abs" "$SANDBOX/escape-rel/x" "$SANDBOX/linuxbrew $SANDBOX/escape-abs/bin"; do
    ( LAPTOP_BREW_DIRS="$bad"; guard_sandbox 2>/dev/null )
    check "rejects symlink escape '${bad//$SANDBOX/<sandbox>}'" [ $? -ne 0 ]
  done
  HOME="$SANDBOX/escape-rel" guard_sandbox 2>/dev/null
  check "rejects a HOME that links outside" [ $? -ne 0 ]
  ( LAPTOP_BREW_DIRS="$SANDBOX/escape-abs"; run_linux --dry-run ) >/dev/null 2>&1
  check "run_linux refuses a symlink-escaping brew prefix" [ $? -eq 2 ]
  ( LAPTOP_BREW_DIRS="$SANDBOX/a $SANDBOX/b"; guard_sandbox )
  check "accepts several sandbox entries" [ $? -eq 0 ]
  HOME=/var/home/somebody guard_sandbox 2>/dev/null
  check "rejects a host HOME" [ $? -ne 0 ]
  ( LAPTOP_BREW_DIRS=/home/linuxbrew/.linuxbrew; run_linux --dry-run ) >/dev/null 2>&1
  check "run_linux refuses to start" [ $? -eq 2 ]
  check "script never ran" [ ! -s "$LOG" ]
  teardown
}

test_backup_edge_cases() {
  setup "mv reports success without moving"
  bazzite
  dotfiles_fixture
  stub mv 'exit 0'
  echo "keep me" > "$HOME/.bashrc"
  run_linux
  check "detects the no-op move" has "$OUT" "moving $HOME/.bashrc to .* did not take effect"
  check "skips stowing bash" has "$OUT" "skipped stowing bash"
  check "original untouched" grep -qx "keep me" "$HOME/.bashrc"
  check "not listed as backed up" lacks "$OUT" "backed up ~/.bashrc"
  teardown

  setup "backup destination already occupied"
  bazzite
  dotfiles_fixture
  mkdir -p "$STATE/fixed-backup"
  echo "older backup" > "$STATE/fixed-backup/.bashrc"
  stub mktemp 'if [ "$1" = -d ]; then echo "$STUB_STATE/fixed-backup"; else exec "$STUB_STATE/../sysbin/mktemp" "$@"; fi'
  echo "current" > "$HOME/.bashrc"
  run_linux
  check "refuses the occupied destination" has "$OUT" "backup destination $STATE/fixed-backup/.bashrc already exists"
  check "skips stowing bash" has "$OUT" "skipped stowing bash"
  check "older backup untouched" grep -qx "older backup" "$STATE/fixed-backup/.bashrc"
  check "current file untouched" grep -qx "current" "$HOME/.bashrc"
  teardown

  setup "backup dir cannot be created"
  bazzite
  dotfiles_fixture
  mkdir -p "$HOME/.local/state/laptop"
  echo "not a dir" > "$HOME/.local/state/laptop/backups"
  echo "current" > "$HOME/.bashrc"
  run_linux
  check "reports it" has "$OUT" "could not create a backup directory"
  check "skips stowing bash" has "$OUT" "skipped stowing bash"
  check "current file untouched" grep -qx "current" "$HOME/.bashrc"
  check "run still completes" [ "$RC" -eq 0 ]
  teardown
}

test_rpm_ostree_status_shapes() {
  setup "bazzite dry-run (pending, not staged)"
  bazzite
  dotfiles_fixture
  echo '{"deployments":[{"booted":false,"staged":false,"requested-packages":["ghostty"]},{"booted":true,"requested-packages":[]}]}' > "$STATE/ostree-status"
  run_linux --dry-run
  check "unstaged pending counts as layered" has "$OUT" "ghostty already layered"
  check "no rpm-ostree install" lacks "$OUT" "rpm-ostree install"
  teardown

  local shape
  for shape in 'not json {' '[]' '{"deployments":"x"}' '{"deployments":[1,2]}'; do
    setup "bazzite dry-run (malformed status: $shape)"
    bazzite
    dotfiles_fixture
    echo "$shape" > "$STATE/ostree-status"
    run_linux --dry-run
    check "exits 0" [ "$RC" -eq 0 ]
    check "falls back to an idempotent install" has "$OUT" '\[dry-run\] rpm-ostree install --idempotent ghostty$'
    teardown
  done
}

# ── Tests: Bazzite stubbed run ───────────────────────────────────────────────

test_bazzite_run_and_rerun() {
  setup "bazzite run + re-run (stubbed)"
  bazzite
  dotfiles_fixture
  stub tmux
  printf 'my old bashrc\n' > "$HOME/.bashrc"

  run_linux
  check "first run exits 0" [ "$RC" -eq 0 ]
  local backup
  backup="$(find "$HOME/.local/state/laptop/backups" -name .bashrc -type f 2>/dev/null | head -1)"
  check "old ~/.bashrc was backed up" [ -n "$backup" ]
  check "backup keeps the original content" grep -qx "my old bashrc" "${backup:-/nonexistent}"
  check ".bashrc now links into dotfiles" [ "$(readlink "$HOME/.bashrc")" = "$HOME/Projects/Home/dotfiles/bash/.bashrc" ]
  check ".tmux.conf is stowed" [ -L "$HOME/.tmux.conf" ]
  check "dotfiles copy was not overwritten (no adopt)" grep -qx "# dotfiles bashrc" "$HOME/Projects/Home/dotfiles/bash/.bashrc"
  check "brew install ran once" [ "$(log_count '^brew install')" -eq 1 ]
  check "rpm-ostree install ran once" [ "$(log_count '^rpm-ostree install')" -eq 1 ]
  check "rpm-ostree layered only ghostty" log_has '^rpm-ostree install --idempotent ghostty$'
  check "stow never got --adopt" log_lacks '^stow .*--adopt'
  check "stow ran for tmux" log_has '^stow .* tmux$'
  check "no sudo/apt/chsh/ujust/flatpak/reboot" log_lacks '^(sudo|apt-get|chsh|usermod|ujust|flatpak|systemctl)( |$)'
  check "prints reboot notice" has "$OUT" "Reboot required.*ghostty"
  check "mise came from Homebrew" log_has '^brew install .* mise( |$)'
  check "node lts pinned via mise, once" [ "$(log_count '^mise use -g node@lts$')" -eq 1 ]
  check "mise wrote its global config" [ "$(cat "$HOME/.config/mise/config.toml" 2>/dev/null)" = "$(printf '[tools]\nnode = "lts"')" ]
  check "node is installed under mise" [ -x "$HOME/.local/share/mise/installs/node/22.12.0/bin/node" ]
  check "fnm never involved" log_lacks '^fnm |fnm'
  check "claude installed with npm after node" log_has '^npm install -g @anthropic-ai/claude-code$'

  : > "$LOG"
  local backups_before mise_conf_before
  backups_before="$(find "$HOME/.local/state/laptop/backups" -type f | wc -l)"
  mise_conf_before="$(cat "$HOME/.config/mise/config.toml")"
  run_linux
  check "re-run exits 0" [ "$RC" -eq 0 ]
  check "re-run installs nothing with brew" log_lacks '^brew install'
  check "re-run does not layer again" log_lacks '^rpm-ostree install'
  check "re-run makes no new backups" [ "$(find "$HOME/.local/state/laptop/backups" -type f | wc -l)" -eq "$backups_before" ]
  check "re-run does not regenerate the SSH key" log_lacks '^ssh-keygen'
  check "re-run has no stow failures" lacks "$OUT" "stow failed"
  check "re-run does not run mise" log_lacks '^mise '
  check "re-run reports node installed via mise" has "$OUT" "node already installed via mise"
  check "re-run leaves mise config unchanged" [ "$mise_conf_before" = "$(cat "$HOME/.config/mise/config.toml")" ]
  teardown
}

test_bazzite_layer_failure() {
  setup "bazzite run (rpm-ostree fails)"
  bazzite
  dotfiles_fixture
  STUB_OSTREE_RC=1 run_linux
  check "run still completes" [ "$RC" -eq 0 ]
  check "tried rpm-ostree exactly once (no loop)" [ "$(log_count '^rpm-ostree install')" -eq 1 ]
  check "explains the Terra metadata fix" has "$OUT" "rpm-ostree refresh-md --force"
  check "no reboot notice after failure" lacks "$OUT" "Reboot required"
  teardown
}

# ── Tests: Ubuntu / Pop!_OS dry run ──────────────────────────────────────────

test_debian_dry_run() {
  setup "pop dry-run"
  os_release pop "ubuntu debian"
  dotfiles_fixture
  echo "# distro bashrc" > "$HOME/.bashrc"
  local before; before="$(home_snapshot)"
  run_linux --dry-run
  check "exits 0" [ "$RC" -eq 0 ]
  check "detects Debian family" has "$OUT" "Detected Debian/Ubuntu/Pop"
  check "plans apt-get update" has "$OUT" "\[dry-run\] sudo apt-get update -qq"
  check "plans apt install zsh" has "$OUT" "\[dry-run\] sudo apt-get install -y zsh$"
  check "plans gh apt repo" has "$OUT" "/etc/apt/sources.list.d/github-cli.list"
  check "plans chsh" has "$OUT" "\[dry-run\] chsh -s"
  check "stows tmux" has "$OUT" "\[dry-run\] stow .* --restow tmux$"
  check "never uses --adopt" lacks "$OUT" "--adopt"
  check "backs up instead of adopting" has "$OUT" "would back up ~/.bashrc"
  check "no brew / rpm-ostree" lacks "$OUT" "(brew install|rpm-ostree)"
  check "plans mise's apt signing key" has "$OUT" "\[dry-run\] curl -fsSL https://mise.jdx.dev/gpg-key.pub \| gpg --dearmor \| sudo tee /etc/apt/keyrings/mise-archive-keyring.gpg"
  check "plans mise's apt repo" has "$OUT" "https://mise.jdx.dev/deb stable main.*sudo tee /etc/apt/sources.list.d/mise.list"
  check "plans apt install mise" has "$OUT" "\[dry-run\] sudo apt-get install -y mise$"
  check "plans node lts via mise" has "$OUT" "\[dry-run\] mise use -g node@lts$"
  check "mise is not run at all (it creates state)" log_lacks '^mise '
  check "no fnm anywhere in the plan" lacks "$OUT" "fnm"
  check "no mutating command was executed" log_lacks "$MUTATING"
  check "HOME is untouched" [ "$before" = "$(home_snapshot)" ]
  teardown

  setup "pop dry-run (mise in ~/.local/bin, node installed)"
  os_release pop "ubuntu debian"
  dotfiles_fixture
  mise_node_fixture
  mkdir -p "$HOME/.local/bin"
  mv "$STUBS/mise" "$HOME/.local/bin/mise"   # mise's own installer puts it here
  before="$(home_snapshot)"
  run_linux --dry-run
  check "exits 0" [ "$RC" -eq 0 ]
  check "finds mise in ~/.local/bin" has "$OUT" "mise already installed \($HOME/.local/bin/mise\)"
  check "no mise apt repo planned" lacks "$OUT" "mise.jdx.dev|apt-get install -y mise"
  check "node found on disk" has "$OUT" "node already installed via mise"
  check "mise is not run at all" log_lacks '^mise '
  check "HOME is untouched" [ "$before" = "$(home_snapshot)" ]
  teardown
}

# ── Tests: Ubuntu / Pop!_OS stubbed run ──────────────────────────────────────

test_debian_run_and_rerun() {
  setup "pop run + re-run (stubbed)"
  os_release pop "ubuntu debian"
  dotfiles_fixture
  run_linux
  check "first run exits 0" [ "$RC" -eq 0 ]
  check "mise installed from its apt repo" log_has '^sudo apt-get install -y mise$'
  check "apt repo written before the install" [ "$(grep -nE '^sudo (tee /etc/apt/sources.list.d/mise.list|apt-get install -y mise)' "$LOG" | cut -d: -f2- | tr '\n' '|')" = "sudo tee /etc/apt/sources.list.d/mise.list|sudo apt-get install -y mise|" ]
  check "node lts pinned via mise, once" [ "$(log_count '^mise use -g node@lts$')" -eq 1 ]
  check "mise wrote its global config" [ "$(cat "$HOME/.config/mise/config.toml" 2>/dev/null)" = "$(printf '[tools]\nnode = "lts"')" ]
  check "no fnm installer" log_lacks 'fnm'
  local conf_before; conf_before="$(cat "$HOME/.config/mise/config.toml")"
  : > "$LOG"
  run_linux
  check "re-run exits 0" [ "$RC" -eq 0 ]
  check "re-run skips mise install" has "$OUT" "mise already installed"
  check "re-run adds no mise apt repo" log_lacks 'mise\.list|mise-archive-keyring|apt-get install -y mise'
  check "re-run does not run mise" log_lacks '^mise '
  check "re-run leaves mise config unchanged" [ "$conf_before" = "$(cat "$HOME/.config/mise/config.toml")" ]
  teardown
}

# ── Tests: mise edge cases ───────────────────────────────────────────────────

test_mise_edge_cases() {
  setup "node pinned in mise config but not installed"
  bazzite
  dotfiles_fixture
  cp "$STATE/mise-stub" "$STUBS/mise"
  mkdir -p "$HOME/.config/mise"
  printf '# mine\n[settings]\nexperimental = true\n\n[tools]\n  "node" = "20"  # pinned\n' > "$HOME/.config/mise/config.toml"
  local conf_before; conf_before="$(cat "$HOME/.config/mise/config.toml")"
  run_linux --dry-run
  check "dry run plans installing the pinned node" has "$OUT" "\[dry-run\] $STUBS/mise install node$"
  check "dry run does not re-pin to lts" lacks "$OUT" "mise use"
  check "dry run does not run mise" log_lacks '^mise '
  run_linux
  check "run installs the pinned node" log_has '^mise install node$'
  check "run does not re-pin" log_lacks '^mise use'
  check "config left as the user wrote it" [ "$conf_before" = "$(cat "$HOME/.config/mise/config.toml")" ]
  teardown

  setup "node outside [tools] does not count"
  bazzite
  dotfiles_fixture
  cp "$STATE/mise-stub" "$STUBS/mise"
  mkdir -p "$HOME/.config/mise" "$HOME/.local/share/mise/installs/node/18.0.0/bin"
  touch "$HOME/.local/share/mise/installs/node/18.0.0/bin/node"
  printf '[env]\nnode = "not a tool"\n[tools]\npython = "3.12"\n' > "$HOME/.config/mise/config.toml"
  run_linux --dry-run
  check "plans pinning node lts" has "$OUT" "\[dry-run\] $STUBS/mise use -g node@lts$"
  check "does not claim node is installed" lacks "$OUT" "node already installed"
  teardown

  setup "leftover fnm is noted, not removed"
  os_release pop "ubuntu debian"
  dotfiles_fixture
  mkdir -p "$HOME/.local/share/fnm/aliases"
  touch "$HOME/.local/share/fnm/aliases/lts-latest"
  run_linux --dry-run
  check "notes fnm is still installed" has "$OUT" "note: fnm is still installed \($HOME/.local/share/fnm\)"
  check "plans no fnm removal" lacks "$OUT" "\[dry-run\] .*(rm .*fnm|fnm uninstall)"
  run_linux
  check "fnm dir still there after a run" [ -e "$HOME/.local/share/fnm/aliases/lts-latest" ]
  check "fnm dir not backed up" [ -z "$(find "$HOME/.local/state/laptop/backups" -path '*fnm*' 2>/dev/null)" ]
  teardown

  setup "no fnm, no note"
  bazzite
  dotfiles_fixture
  run_linux --dry-run
  check "no fnm note" lacks "$OUT" "fnm"
  teardown
}

# ── Run ──────────────────────────────────────────────────────────────────────

TESTS=(
  test_detection
  test_bazzite_dry_run_fresh
  test_bazzite_dry_run_all_done
  test_bazzite_dry_run_layered_pending
  test_bazzite_dry_run_no_terra
  test_bazzite_symlinked_dirs
  test_bazzite_rollback_only
  test_bazzite_no_brew
  test_backup_timestamp_collision
  test_backup_move_failure
  test_ancestor_file_conflict
  test_run_sh_pipefail
  test_folded_into_other_package
  test_isolation_sentinels
  test_backup_edge_cases
  test_rpm_ostree_status_shapes
  test_bazzite_run_and_rerun
  test_bazzite_layer_failure
  test_debian_dry_run
  test_debian_run_and_rerun
  test_mise_edge_cases
  test_hand_made_repo_links
)

for t in "${TESTS[@]}"; do
  printf "%s\n" "$t"
  "$t"
done

printf "\n%d test functions, %d assertions: %d passed, %d failed\n" "${#TESTS[@]}" "$((PASS + FAIL))" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
