#!/usr/bin/env bash
# Plain-bash tests for ./linux: platform detection, the --dry-run plan, and a
# stubbed "real" run (backups instead of --adopt, idempotent re-run).
#
# Nothing real is installed: every external command the script can call is a
# stub that logs its arguments, and PATH holds only those stubs plus a sandbox
# of core utilities. HOME is a throwaway directory.
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
CORE_UTILS=(bash env cat grep sed find realpath dirname basename date mkdir mv cp rm ln chmod head tr sort mktemp touch readlink ls wc)

ALL_FORMULAE=(git git-delta stow neovim tmux jq ripgrep fd fzf bat wget gh starship zsh zsh-autosuggestions zsh-syntax-highlighting uv fnm)
ALL_PACKAGES=(agy bash bat bin ghostty git nvim ripgrep ssh starship tmux zsh)

# Calls that would change the machine. None may appear during --dry-run.
MUTATING='^(sudo|apt-get|chsh|usermod|ujust|ssh-keygen|npm|curl|stow|systemctl|ubuntu-report|unzip|fc-cache)( |$)|^brew install|^rpm-ostree (install|upgrade|reboot)|^flatpak install|^git (clone|config)|^fnm (install|default)'

# ── Assertions ───────────────────────────────────────────────────────────────

pass() { PASS=$((PASS + 1)); printf "  ok   %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  FAIL %s\n" "$1"; }

check() { # check "description" command...
  local desc="$1"; shift
  if "$@"; then pass "$CURRENT: $desc"; else fail "$CURRENT: $desc"; fi
}

has()      { grep -qE -- "$2" <<<"$1"; }
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
  export LAPTOP_OS_RELEASE="$SANDBOX/os-release"
  mkdir -p "$STUBS" "$STATE" "$SANDBOX/sysbin" "$HOME" "$LAPTOP_YUM_REPOS_DIR"
  : > "$LOG"
  : > "$STATE/brew-installed"
  : > "$STATE/rpm-installed"
  echo '{"deployments":[{"booted":true,"requested-packages":[]}]}' > "$STATE/ostree-status"
  touch "$LAPTOP_YUM_REPOS_DIR/terra.repo"

  local u
  for u in "${CORE_UTILS[@]}"; do
    ln -s "$(command -v "$u")" "$SANDBOX/sysbin/$u"
  done

  stub sudo; stub apt-get; stub chsh; stub usermod; stub ujust; stub flatpak
  stub systemctl; stub npm; stub curl; stub unzip; stub fc-cache
  stub dpkg 'exit 1'
  stub fc-list 'echo "/x/JetBrainsMonoNerdFont-Regular.ttf: JetBrainsMono Nerd Font:style=Regular"'
  stub git 'if [ "$1" = clone ]; then mkdir -p "$3/.git"; fi'
  stub ssh-keygen 'while [ $# -gt 0 ]; do [ "$1" = -f ] && { touch "$2" "$2.pub"; break; }; shift; done'
  stub fnm 'case "$1" in --version) echo "fnm 1.0";; esac'
  stub brew '
case "$1" in
  list)     grep -qx -- "${!#}" "$STUB_STATE/brew-installed" ;;
  install)  shift; printf "%s\n" "$@" >> "$STUB_STATE/brew-installed" ;;
  --prefix) echo /home/linuxbrew/.linuxbrew ;;
  shellenv) : ;;
esac'
  stub rpm '[ "$1" = -q ] && grep -qx -- "$2" "$STUB_STATE/rpm-installed"'
  stub rpm-ostree '
case "$1" in
  status)  cat "$STUB_STATE/ostree-status" ;;
  install) [ "${STUB_OSTREE_RC:-0}" = 0 ] || { echo "error: Checksum mismatch (terra)" >&2; exit 1; }
           shift; for p; do [ "$p" = --idempotent ] || echo "{\"requested-packages\":[\"$p\"]}" >> "$STUB_STATE/ostree-status"; done ;;
esac'
  # A minimal stow: links each file, and like real stow refuses to overwrite.
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
for p in "${pkgs[@]}"; do
  while IFS= read -r f; do
    f="${f#./}"; t="$target/$f"; s="$dir/$p/$f"
    if [ -L "$t" ] && [ "$(readlink "$t")" = "$s" ]; then continue; fi
    if [ -e "$t" ] || [ -L "$t" ]; then echo "stub stow: conflict on $t" >&2; exit 1; fi
    mkdir -p "$(dirname "$t")"; ln -s "$s" "$t"
  done < <(cd "$dir/$p" && find . \( -type f -o -type l \))
done'
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

# Everything already in place, as after a successful run.
all_done_fixture() {
  printf "%s\n" "${ALL_FORMULAE[@]}" > "$STATE/brew-installed"
  echo ghostty > "$STATE/rpm-installed"
  mkdir -p "$HOME/.ssh" "$HOME/.bun/bin"
  touch "$HOME/.ssh/id_ed25519"
  printf '#!%s\necho 1.1.0\n' "$SANDBOX/sysbin/bash" > "$HOME/.bun/bin/bun"; chmod +x "$HOME/.bun/bin/bun"
  stub claude
  stub fnm 'case "$1" in list) echo "* v22.0.0 default, lts-latest";; --version) echo "fnm 1.0";; esac'
  "$STUBS/stow" --dir="$HOME/Projects/Home/dotfiles" --target="$HOME" --restow "${ALL_PACKAGES[@]}"
  : > "$LOG"
}

home_snapshot() {
  (cd "$HOME" && find . -printf '%p %y %s %l\n' | sort
   find . -type f -exec cat {} + 2>/dev/null)
}

run_linux() { # run_linux ARGS... — sets OUT and RC
  OUT="$(PATH="$STUBS:$SANDBOX/sysbin" SHELL=/bin/bash "$SANDBOX/sysbin/bash" "$SCRIPT" "$@" 2>&1)"
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
  for f in zsh zsh-autosuggestions zsh-syntax-highlighting git-delta neovim ripgrep fd fzf bat jq gh starship uv wget; do
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
  check "backup is timestamped" has "$OUT" "\[dry-run\] mv $HOME/.bashrc $HOME/.local/state/laptop/backups/[0-9]{8}-[0-9]{6}/.bashrc"
  check "warns about the bling line" has "$OUT" ".bashrc contains the 'ujust bazzite-cli' bling line"
  check "no bling warning for clean ~/.zshrc" lacks "$OUT" ".zshrc contains the"
  check "does not back up a stow-ignored README" lacks "$OUT" "README"
  check "warns ghostty config lacks command =" has "$OUT" "config.ghostty has no 'command =' line"
  check "keeps bash as login shell" has "$OUT" "login shell stays bash"
  check "no apt/sudo/chsh/ujust/flatpak in plan" lacks "$OUT" "\[dry-run\] (sudo|apt-get|chsh|usermod|ujust|flatpak)"
  check "no mutating command was executed" log_lacks "$MUTATING"
  check "HOME is untouched" [ "$before" = "$(home_snapshot)" ]
  check "says nothing was changed" has "$OUT" "Dry run complete"
  teardown
}

test_bazzite_dry_run_all_done() {
  setup "bazzite dry-run (already set up)"
  bazzite
  dotfiles_fixture
  all_done_fixture
  run_linux --dry-run
  check "exits 0" [ "$RC" -eq 0 ]
  check "no brew install" lacks "$OUT" "brew install"
  check "no rpm-ostree install" lacks "$OUT" "rpm-ostree install"
  check "ghostty already installed" has "$OUT" "ghostty already installed"
  check "no reboot needed" lacks "$OUT" "Reboot required"
  check "no backups" lacks "$OUT" "back up"
  check "no ssh-keygen" lacks "$OUT" "ssh-keygen"
  check "no mutating command was executed" log_lacks "$MUTATING"
  teardown
}

test_bazzite_dry_run_layered_pending() {
  setup "bazzite dry-run (ghostty layered, not rebooted)"
  bazzite
  dotfiles_fixture
  echo '{"deployments":[{"booted":false,"requested-packages":["ghostty"]}]}' > "$STATE/ostree-status"
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

  : > "$LOG"
  local backups_before; backups_before="$(find "$HOME/.local/state/laptop/backups" -type f | wc -l)"
  run_linux
  check "re-run exits 0" [ "$RC" -eq 0 ]
  check "re-run installs nothing with brew" log_lacks '^brew install'
  check "re-run does not layer again" log_lacks '^rpm-ostree install'
  check "re-run makes no new backups" [ "$(find "$HOME/.local/state/laptop/backups" -type f | wc -l)" -eq "$backups_before" ]
  check "re-run does not regenerate the SSH key" log_lacks '^ssh-keygen'
  check "re-run has no stow failures" lacks "$OUT" "stow failed"
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
  check "no mutating command was executed" log_lacks "$MUTATING"
  check "HOME is untouched" [ "$before" = "$(home_snapshot)" ]
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
  test_bazzite_run_and_rerun
  test_bazzite_layer_failure
  test_debian_dry_run
)

for t in "${TESTS[@]}"; do
  printf "%s\n" "$t"
  "$t"
done

printf "\n%d test functions, %d assertions: %d passed, %d failed\n" "${#TESTS[@]}" "$((PASS + FAIL))" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
