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
CORE_UTILS=(bash env cat grep sed find realpath dirname basename date mkdir mv cp rm ln chmod head tr sort mktemp touch readlink ls wc python3 sha256sum)

ALL_FORMULAE=(git git-delta stow neovim tmux jq ripgrep fd fzf bat wget gh starship zsh zsh-autosuggestions zsh-syntax-highlighting uv mise openjdk@21 lazygit tree-sitter-cli shellcheck markdownlint-cli2 gitleaks)
ALL_PACKAGES=(agy applications bash bat bin claude ghostty git nvim render-url ripgrep ssh starship tmux zsh)
# Stowed with --no-folding (as the script does).
NO_FOLD_PACKAGES=(agy applications bin claude render-url)

# Calls that would change the machine. None may appear during --dry-run.
MUTATING='^(sudo|apt-get|chsh|usermod|ujust|ssh-keygen|npm|curl|stow|systemctl|ubuntu-report|unzip|fc-cache)( |$)|^brew install|^rpm-ostree (install|upgrade|reboot)|^flatpak install|^git clone|^git config (--global [^-]|.* --(add|unset|unset-all|replace-all|remove-section|rename-section)( |$))|^mise (use|install|reshim|exec)|^mise-|^gsettings set'

# rpm-ostree status --json shapes. Deployments are listed newest first:
# staged/pending, then booted, then rollback.
BOOTED_ONLY='{"deployments":[{"booted":true,"requested-packages":[],"packages":[]}]}'
PENDING_GHOSTTY='{"deployments":[{"booted":false,"staged":true,"requested-packages":["ghostty"],"packages":["ghostty"]},{"booted":true,"requested-packages":[]}]}'
ROLLBACK_GHOSTTY='{"deployments":[{"booted":true,"requested-packages":[],"packages":[]},{"booted":false,"requested-packages":["ghostty"],"packages":["ghostty"]}]}'

# A mise that models its filesystem side effects. Like real mise, every
# invocation leaves state and cache dirs behind; `use -g node@lts` writes the
# global config and installs node; `install node` installs the pinned version
# (a no-op if it is already installed, shims included); `reshim` rebuilds the
# shims from what is installed. Installs and shims come from node-install (see
# write_node_install). It resolves its dirs from the same MISE_*/XDG_*
# variables as real mise. STUB_MISE_RC makes use/install fail and
# STUB_RESHIM_RC makes reshim fail.
MISE_SIDE_EFFECTS='
conf="${MISE_GLOBAL_CONFIG_FILE:-${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}/config.toml}"
mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/mise" "${XDG_CACHE_HOME:-$HOME/.cache}/mise"
case "$*" in
  --version)         echo "2026.9.0 linux-x64 (stub)" ;;
  "use -g node@lts") [ "${STUB_MISE_RC:-0}" = 0 ] || exit "$STUB_MISE_RC"
                     mkdir -p "${conf%/*}"; printf "[tools]\nnode = \"lts\"\n" >> "$conf"
                     "$STUB_STATE/node-install" lts ;;
  "install node")    [ "${STUB_MISE_RC:-0}" = 0 ] || exit "$STUB_MISE_RC"
                     "$STUB_STATE/node-install" "$("$STUB_STATE/node-install" --pin)" ;;
  reshim)            [ "${STUB_RESHIM_RC:-0}" = 0 ] || exit "$STUB_RESHIM_RC"
                     "$STUB_STATE/node-install" --reshim ;;
  "exec -- "*)       shift 2  # the pinned node first on PATH, as mise exec does
                     v="$("$STUB_STATE/node-install" --which)"
                     PATH="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/installs/node/$v/bin:$PATH" exec "$@" ;;
  *)                 echo "stub mise: unexpected: $*" >&2; exit 2 ;;
esac'

# node-install models what mise leaves on disk for node:
#   node-install SEL   install the version SEL resolves to (installs/node/<v>/bin
#                      with node and npm, plus the prefix/alias links mise makes:
#                      22, 22.12, and lts/latest for 22.12.0), then reshim — only
#                      if that version wasn't installed yet. NODE_NO_ALIAS=1 skips
#                      the lts/latest links.
#   --reshim           one shim per executable in any installed version's bin
#   --pin / --which    the config's node selection / the version it resolves to
# Each tool logs as "mise-<version>-<tool>" and each shim as "mise-shim-<tool>";
# a shim runs the pinned version's tool, as mise's shims do. The versioned
# npm's `install -g` of @anthropic-ai/claude-code, @openai/codex or
# @earendil-works/pi-coding-agent adds claude, codex or pi to that bin dir, not
# a shim: only reshim exposes it (STUB_AGENT_FAIL=<package> makes that install
# fail). `corepack enable pnpm` adds pnpm next to the corepack that runs, as
# real corepack does for the first corepack on PATH (STUB_COREPACK_RC makes it
# fail). `npm ci` replaces ./node_modules with one
# holding playwright (STUB_NPM_CI_RC makes it fail). `npx playwright install
# chromium` behaves like Playwright: it needs its pinned revision (1140) of
# both chromium and chromium_headless_shell in ~/.cache/ms-playwright and
# downloads (logged to $STUB_STATE/pw-downloads) only the ones missing;
# STUB_PW_RC makes it fail before downloading anything.
write_node_install() {
  cat > "$STATE/node-install" <<'EOF'
#!@BASH@
data="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}"
conf="${MISE_GLOBAL_CONFIG_FILE:-${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}/config.toml}"
dir="$data/installs/node"
resolve() {
  case "$1" in
    ""|lts|latest|22|22.*) echo 22.12.0 ;;
    20|20.*)               echo 20.18.1 ;;
    *)                     echo "$1" ;;
  esac
}
pin() {
  python3 -I -c '
import sys, tomllib
try:
    v = tomllib.load(open(sys.argv[1], "rb")).get("tools", {}).get("node", "")
except Exception:
    v = ""
if isinstance(v, dict): v = v.get("version", "")
if isinstance(v, list): v = v[0] if v else ""
print(v)' "$conf"
}
tool() { # tool PATH LABEL
  cat > "$1" <<TOOL
#!@BASH@
printf '%s\n' "mise-$2 \$*" >> "\$STUB_LOG"
if [ "\${0##*/}" = node ] && [ -f "\$STUB_STATE/sf-node-fail" ]; then
  exit 1
elif [ "\${0##*/}" = npm ] && [ "\${1:-} \${2:-}" = "install -g" ] && [[ "\${3:-}" =~ ^(@anthropic-ai/claude-code|@openai/codex|@earendil-works/pi-coding-agent)$ ]]; then
  [ "\${STUB_AGENT_FAIL:-}" != "\$3" ] || exit 1
  case "\$3" in *claude-code) c=claude ;; *codex) c=codex ;; *) c=pi ;; esac
  printf '#!@BASH@\nexit 0\n' > "\${0%/*}/\$c"; chmod +x "\${0%/*}/\$c"
elif [ "\${0##*/} \$*" = "corepack enable pnpm" ]; then
  [ "\${STUB_COREPACK_RC:-0}" = 0 ] || exit "\$STUB_COREPACK_RC"
  printf '#!@BASH@\nexit 0\n' > "\${0%/*}/pnpm"; chmod +x "\${0%/*}/pnpm"
elif [ "\${0##*/}" = npm ] && [ "\${1:-}" = list ]; then
  [ -f "\$STUB_STATE/\${!#}" ]; exit \$?
elif [ "\${0##*/}" = npm ] && [ "\${1:-}" = install ]; then
  [ ! -f "\$STUB_STATE/sf-npm-fail" ] || exit 1
  for pkg in "\$@"; do
    case "\$pkg" in
      @salesforce/*)
        mkdir -p "\$STUB_STATE/@salesforce"; touch "\$STUB_STATE/\$pkg"
        if [ "\$pkg" = @salesforce/cli ]; then
          cp "\$STUB_STATE/sf-tool" "\${0%/*}/sf"
        else
          cp "\$STUB_STATE/sf-tool" "\${0%/*}/lwc-language-server"
        fi ;;
    esac
  done
elif [ "\${0##*/} \$*" = "npm ci" ]; then
  [ "\${STUB_NPM_CI_RC:-0}" = 0 ] || exit "\$STUB_NPM_CI_RC"
  rm -rf node_modules; mkdir -p node_modules/playwright
elif [ "\${0##*/} \$*" = "npx playwright install chromium" ]; then
  [ "\${STUB_PW_RC:-0}" = 0 ] || { echo "Failed to install browsers" >&2; exit "\$STUB_PW_RC"; }
  for b in chromium-1140 chromium_headless_shell-1140; do
    c="\${XDG_CACHE_HOME:-\$HOME/.cache}/ms-playwright/\$b"
    [ -d "\$c" ] || { mkdir -p "\$c"; echo "\$b" >> "\$STUB_STATE/pw-downloads"; }
  done
fi
TOOL
  chmod +x "$1"
}
reshim() {
  local b n
  rm -rf "$data/shims"; mkdir -p "$data/shims"
  for b in "$dir"/*/bin/*; do
    [ -x "$b" ] && [ ! -L "${b%/bin/*}" ] || continue
    n="${b##*/}"
    cat > "$data/shims/$n" <<SHIM
#!@BASH@
printf '%s\n' "mise-shim-$n \$*" >> "\$STUB_LOG"
v="\$("$0" --which)"
[ -x "$dir/\$v/bin/$n" ] || { echo "mise: $n is not installed for node \$v" >&2; exit 127; }
exec "$dir/\$v/bin/$n" "\$@"
SHIM
    chmod +x "$data/shims/$n"
  done
}
case "$1" in
  --pin)    pin; exit 0 ;;
  --which)  resolve "$(pin)"; exit 0 ;;
  --reshim) reshim; exit 0 ;;
esac
v="$(resolve "$1")"
[ -x "$dir/$v/bin/node" ] && exit 0 # already installed: nothing to do
mkdir -p "$dir/$v/bin"
tool "$dir/$v/bin/node" "$v-node"
tool "$dir/$v/bin/npm" "$v-npm"
tool "$dir/$v/bin/npx" "$v-npx"
tool "$dir/$v/bin/corepack" "$v-corepack"
ln -sfn "$v" "$dir/${v%%.*}"; ln -sfn "$v" "$dir/${v%.*}"
if [ "$v" = 22.12.0 ] && [ -z "${NODE_NO_ALIAS:-}" ]; then ln -sfn "$v" "$dir/lts"; ln -sfn "$v" "$dir/latest"; fi
reshim
EOF
  sed -i "s|@BASH@|$SANDBOX/sysbin/bash|g" "$STATE/node-install"
  chmod +x "$STATE/node-install"
}

# The git stub. `git config --file F` (reads, and writes to
# ~/.gitconfig.local) and `git config --global --get...` (reads of ~/.gitconfig
# and ~/.config/git/config) run the real git, and only when every file it
# would read resolves inside HOME (no "..", no symlink out). With --includes,
# that covers every include/includeIf target, recursively. Otherwise the call
# is refused with exit 98. Every other git call, --global writes included, is a
# logged no-op. Test hooks:
#   STUB_GIT_FAIL=S           a call whose arguments contain S fails (no output)
#   STUB_GIT_TRUNC=S          a call containing S prints 20 bytes of its output, then fails
#   STUB_GIT_ON=S STUB_GIT_DO=CMD   CMD runs (eval) before a call containing S
write_git_stub() {
  cat > "$STUBS/git" <<'EOF'
#!@BASH@
printf '%s\n' "git $*" >> "$STUB_LOG"
real="$STUB_STATE/real/git"
if [ -n "${STUB_GIT_FAIL:-}" ] && [[ "$*" == *"$STUB_GIT_FAIL"* ]]; then exit 1; fi
if [ -n "${STUB_GIT_ON:-}" ] && [[ "$*" == *"$STUB_GIT_ON"* ]]; then eval "$STUB_GIT_DO"; fi
home="$(realpath -m -- "$HOME")"
inside() {
  case "/$1/" in */../*) return 1 ;; esac
  [[ "$(realpath -m -- "$1")" == "$home"/* ]]
}
includes_inside() { # includes_inside FILE DEPTH
  local f="$1" entry p
  [ "$2" -lt 10 ] || return 1
  [ -e "$f" ] || return 0
  while IFS= read -r -d '' entry; do
    p="${entry#*$'\n'}"
    case "$p" in "~/"*) p="$HOME/${p#\~/}" ;; /*) ;; *) p="$(dirname -- "$f")/$p" ;; esac
    inside "$p" && includes_inside "$p" $(($2 + 1)) || return 1
  done < <(GIT_CONFIG_NOSYSTEM=1 "$real" config --file "$f" --no-includes --null --get-regexp '^include(if)?\..*path$' 2>/dev/null)
}
case "$1 ${2:-}" in
  "clone "*)        mkdir -p "$3/.git"; exit 0 ;;
  "config --file")  files=("$3"); export GIT_CONFIG_GLOBAL=/dev/null ;;
  "config --global") case " $* " in *" --get"*) ;; *) exit 0 ;; esac
                    files=("$HOME/.gitconfig" "${XDG_CONFIG_HOME:-$HOME/.config}/git/config") ;;
  *)                exit 0 ;;
esac
for f in "${files[@]}"; do
  inside "$f" || { echo "stub git: config file outside HOME: $f" >&2; exit 98; }
  if [[ " $* " == *" --includes "* ]]; then
    includes_inside "$f" 0 || { echo "stub git: include outside HOME in $f" >&2; exit 98; }
  fi
done
export GIT_CONFIG_NOSYSTEM=1
if [ -n "${STUB_GIT_TRUNC:-}" ] && [[ "$*" == *"$STUB_GIT_TRUNC"* ]]; then
  "$real" "$@" | head -c 20; exit 1
fi
exec "$real" "$@"
EOF
  sed -i "s|@BASH@|$SANDBOX/sysbin/bash|g" "$STUBS/git"
  chmod +x "$STUBS/git"
}

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
[ "${1:-} ${2:-} ${3:-}" = "apt-get install -y" ] && printf "%s\n" "${@:4}" >> "$STUB_STATE/apt-installed"
[ "$*" = "apt-get install -y mise" ] && cp "$STUB_STATE/mise-stub" "${0%/*}/mise"; exit 0'
  stub apt-get; stub chsh; stub usermod; stub ujust; stub flatpak
  stub systemctl; stub unzip; stub fc-cache
  # A competing npm on PATH: the script must only use mise's. It fails, loudly.
  stub npm 'echo "stub: PATH npm used instead of mise-managed npm" >&2; exit 97'
  stub sf '
[ ! -f "$STUB_STATE/sf-list-fail" ] || exit 1
if [ "$*" = "plugins" ]; then
  [ ! -f "$STUB_STATE/sf-plugin" ] || echo "@salesforce/plugin-code-analyzer 5.16.0"
elif [ "$*" = "plugins install code-analyzer" ]; then
  [ ! -f "$STUB_STATE/sf-plugin-fail" ] || exit 1
  touch "$STUB_STATE/sf-plugin"
fi'; mv "$STUBS/sf" "$STATE/sf-tool"
  write_node_install
  stub sh '[ -p /dev/stdin ] && cat > /dev/null; exit 0' # `curl ... | sh` installers
  stub curl 'if [ -n "${STUB_CURL_FAIL:-}" ] && [[ "$*" == *"$STUB_CURL_FAIL"* ]]; then exit 22; fi; exit "${STUB_CURL_RC:-0}"'
  stub dpkg 'case "$1" in
  --print-architecture) echo amd64 ;;
  -s) grep -qx -- "$2" "$STUB_STATE/apt-installed" 2>/dev/null ;;
  *) exit 1 ;;
esac'
  stub gpg 'exit "${STUB_GPG_RC:-0}"'
  stub fc-list 'echo "/x/JetBrainsMonoNerdFont-Regular.ttf: JetBrainsMono Nerd Font:style=Regular"'
  mkdir -p "$STATE/real"; ln -s "$(PATH=/usr/bin:/bin type -P git)" "$STATE/real/git" || { echo "missing git" >&2; exit 2; }
  write_git_stub
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
dir="" target="" pkgs=() no_folding=0
for a; do
  case "$a" in
    --no-folding) no_folding=1 ;;
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
      if [ ! -e "$t" ] && [ ! -L "$t" ]; then
        if (( no_folding )); then mkdir "$t"; stow_dir "$s" "$t"; else ln -s "$s" "$t"; fi
      elif [ -L "$t" ] && same "$t" "$s"; then                      # our own fold
        # --restow unstows (removing the fold), then stows again: with
        # --no-folding that makes a real directory, as real stow does.
        if (( no_folding )); then rm "$t"; mkdir "$t"; stow_dir "$s" "$t"; fi
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
  printf '[include]\n\tpath = ~/.gitconfig.local\n[pull]\n\trebase = true\n' > "$d/git/.gitconfig"
  echo "{}" > "$d/agy/.config/agy/permissions.json"
  echo "--theme=x" > "$d/bat/.config/bat/config"
  echo "Host *" > "$d/ssh/.ssh/config"
  echo "" > "$d/starship/.config/starship.toml"
  echo "--smart-case" > "$d/ripgrep/.ripgreprc"
  echo "README — must not be stowed" > "$d/bash/README.md"
  mkdir -p "$d/render-url/.local/share/render-url" "$d/applications/.local/bin" "$d/applications/.local/share/applications"
  echo '{"name":"render-url","dependencies":{"playwright":"^1.48.0"}}' > "$d/render-url/.local/share/render-url/package.json"
  echo '{"lockfileVersion":3}' > "$d/render-url/.local/share/render-url/package-lock.json"
  echo "// render-url" > "$d/render-url/.local/share/render-url/render-url.mjs"
  echo "#!/bin/sh" > "$d/applications/.local/bin/claude-on-mac"
  echo "[Desktop Entry]" > "$d/applications/.local/share/applications/claude-on-mac.desktop"
  mkdir -p "$d/claude/.claude/skills/route-local"
  echo "# dotfiles CLAUDE.md" > "$d/claude/.claude/CLAUDE.md"
  echo "# route-local" > "$d/claude/.claude/skills/route-local/SKILL.md"
}

# render-url's dependencies as a successful run leaves them: node_modules
# stamped with the lockfile's hash, and Chromium in Playwright's cache.
render_url_done_fixture() {
  local dir="$HOME/.local/share/render-url"
  mkdir -p "$dir/node_modules/playwright" "$HOME/.cache/ms-playwright/chromium-1140" \
           "$HOME/.cache/ms-playwright/chromium_headless_shell-1140"
  sha256sum < "$dir/package-lock.json" > "$dir/node_modules/.laptop-package-lock.sha256"
}

# mise on PATH, node pinned in its global config and installed, as
# `mise use -g node@lts` leaves it. Made without running mise.
mise_node_fixture() { # mise_node_fixture [PIN] [INSTALLED_VERSION]
  cp "$STATE/mise-stub" "$STUBS/mise"
  mkdir -p "$HOME/.config/mise"
  printf '[tools]\nnode = "%s"\n' "${1:-lts}" > "$HOME/.config/mise/config.toml"
  sandboxed "$STATE/node-install" "${2:-${1:-lts}}"
}

# Line number of the first log entry matching $1 (0 if none).
log_line() { local n; n="$(grep -nE -m1 -- "$1" "$LOG" | cut -d: -f1)"; echo "${n:-0}"; }
# True if the first match of $1 is logged before the first match of $2.
logged_before() { local a b; a="$(log_line "$1")"; b="$(log_line "$2")"; [ "$a" -gt 0 ] && [ "$b" -gt "$a" ]; }

AGENT_TOOLS=(claude codex pi)
NODE_TOOLS=(node npm npx corepack pnpm)

# The agent CLIs and pnpm installed under mise's Node LTS, reshimmed, and
# linked from ~/.local/bin, as a successful run leaves them. Needs
# mise_node_fixture first.
agent_clis_fixture() {
  local data="$HOME/.local/share/mise" t
  for t in "${AGENT_TOOLS[@]}" pnpm; do
    printf '#!%s\nexit 0\n' "$SANDBOX/sysbin/bash" > "$data/installs/node/22.12.0/bin/$t"
    chmod +x "$data/installs/node/22.12.0/bin/$t"
  done
  sandboxed "$STATE/node-install" --reshim
  mkdir -p "$HOME/.local/bin"
  for t in "${AGENT_TOOLS[@]}"; do ln -s "$data/installs/node/lts/bin/$t" "$HOME/.local/bin/$t"; done
  for t in "${NODE_TOOLS[@]}"; do ln -s "$data/shims/$t" "$HOME/.local/bin/$t"; done
}

# Everything already in place, as after a successful run.
all_done_fixture() {
  printf "%s\n" "${ALL_FORMULAE[@]}" > "$STATE/brew-installed"
  echo ghostty > "$STATE/rpm-installed"
  mkdir -p "$HOME/.ssh" "$HOME/.bun/bin"
  touch "$HOME/.ssh/id_ed25519"
  printf '#!%s\necho 1.1.0\n' "$SANDBOX/sysbin/bash" > "$HOME/.bun/bin/bun"; chmod +x "$HOME/.bun/bin/bun"
  mise_node_fixture
  agent_clis_fixture
  local p folded=()
  for p in "${ALL_PACKAGES[@]}"; do
    [[ " ${NO_FOLD_PACKAGES[*]} " == *" $p "* ]] || folded+=("$p")
  done
  sandboxed "$STUBS/stow" --dir="$HOME/Projects/Home/dotfiles" --target="$HOME" --restow "${folded[@]}"
  sandboxed "$STUBS/stow" --no-folding --dir="$HOME/Projects/Home/dotfiles" --target="$HOME" --restow "${NO_FOLD_PACKAGES[@]}"
  render_url_done_fixture
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
  for v in XDG_CURRENT_DESKTOP STUB_GIT_FAIL STUB_GIT_TRUNC STUB_GIT_ON STUB_GIT_DO STUB_CURL_RC STUB_CURL_FAIL STUB_GPG_RC STUB_MISE_RC STUB_RESHIM_RC STUB_OSTREE_RC STUB_NPM_CI_RC STUB_PW_RC STUB_AGENT_FAIL STUB_COREPACK_RC; do
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
  stub java   # an unrelated system Java must not suppress openjdk@21
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
  for f in zsh zsh-autosuggestions zsh-syntax-highlighting git-delta neovim ripgrep fd fzf bat jq gh starship uv wget mise openjdk@21 lazygit tree-sitter-cli shellcheck markdownlint-cli2 gitleaks; do
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
  check "reports node installed via mise" has "$OUT" 'node already installed via mise \(tools.node = lts in '
  check "no mise use/install planned" lacks "$OUT" "\[dry-run\] mise "
  check "no agent CLI, pnpm or link planned" lacks "$OUT" "\[dry-run\] .*(shims/npm install -g|corepack enable|ln -sfn)"
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
  check "skips Claude with a clear warning" has "$OUT" "skipped agent CLIs: no usable mise-managed Node"
  check "competing PATH npm never used" log_lacks '^npm '
  check "no npm through mise either" log_lacks '^mise-'
  check "no backups made" [ ! -e "$HOME/.local/state/laptop/backups" ]
  teardown
}

# Installed-Node detection must match the pin and need an executable node;
# Claude must only ever be installed through mise's own npm.
test_node_readiness() {
  setup "pinned 20, only 22 installed"
  bazzite
  dotfiles_fixture
  mise_node_fixture 20 22.12.0
  local conf_before before; conf_before="$(cat "$HOME/.config/mise/config.toml")"
  before="$(home_snapshot)"
  run_linux --dry-run
  check "dry run: 22 does not satisfy the pin" lacks "$OUT" "node already installed"
  check "dry run: plans installing the pinned node" has "$OUT" "\[dry-run\] $STUBS/mise install node$"
  check "dry run: does not re-pin" lacks "$OUT" "\[dry-run\] .*mise use"
  check "dry run: mise not run" log_lacks '^mise '
  check "dry run: HOME is untouched" [ "$before" = "$(home_snapshot)" ]
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "runs mise install node" log_has '^mise install node$'
  check "node 20 is now installed" [ -x "$HOME/.local/share/mise/installs/node/20.18.1/bin/node" ]
  check "pin unchanged" [ "$conf_before" = "$(cat "$HOME/.config/mise/config.toml")" ]
  check "claude through mise's npm shim, after node" logged_before '^mise install node$' '^mise-shim-npm install -g @anthropic-ai/claude-code$'
  check "PATH npm never used" log_lacks '^npm '
  teardown

  setup "pinned lts, installed node not executable"
  bazzite
  dotfiles_fixture
  mise_node_fixture lts
  chmod -x "$HOME/.local/share/mise/installs/node/22.12.0/bin/node"
  run_linux --dry-run
  check "dry run: not counted as installed" lacks "$OUT" "node already installed"
  check "dry run: plans mise install node" has "$OUT" "\[dry-run\] $STUBS/mise install node$"
  check "dry run: mise not run" log_lacks '^mise '
  run_linux
  check "run reinstalls through mise" log_has '^mise install node$'
  check "node is executable afterwards" [ -x "$HOME/.local/share/mise/installs/node/22.12.0/bin/node" ]
  teardown

  setup "installed but shims missing"
  bazzite
  dotfiles_fixture
  mise_node_fixture lts
  rm -rf "$HOME/.local/share/mise/shims"
  run_linux
  check "not counted as ready" lacks "$OUT" "node already installed"
  check "reshims after install" logged_before '^mise install node$' '^mise reshim$'
  check "shims restored (install alone is a no-op)" [ -x "$HOME/.local/share/mise/shims/npm" ]
  check "claude through the restored shim" log_has '^mise-shim-npm install -g @anthropic-ai/claude-code$'
  teardown

  setup "shims missing, reshim fails"
  bazzite
  dotfiles_fixture
  mise_node_fixture lts
  rm -rf "$HOME/.local/share/mise/shims"
  STUB_RESHIM_RC=1 run_linux
  check "run completes" [ "$RC" -eq 0 ]
  check "reshim failure has its own warning" has "$OUT" "'mise reshim' failed after installing node"
  check "not reported as an install failure" lacks "$OUT" "'mise install node' failed"
  check "skips Claude" has "$OUT" "skipped agent CLIs"
  check "no npm of any kind" log_lacks 'npm'
  teardown

  setup "no installs/node/lts link"
  bazzite
  dotfiles_fixture
  mise_node_fixture lts
  rm "$HOME/.local/share/mise/installs/node/lts"
  stub claude
  local conf_before; conf_before="$(cat "$HOME/.config/mise/config.toml")"
  run_linux --dry-run
  check "dry run: lts not proven without the link" lacks "$OUT" "node already installed"
  check "dry run: plans reconciling with mise" has "$OUT" "\[dry-run\] $STUBS/mise install node$"
  check "dry run: mise not run" log_lacks '^mise '
  run_linux
  : > "$LOG"
  run_linux
  check "every run reconciles again" [ "$(log_count '^mise (install node|reshim)$')" -eq 2 ]
  check "never re-pins" log_lacks '^mise use'
  check "config unchanged" [ "$conf_before" = "$(cat "$HOME/.config/mise/config.toml")" ]
  teardown

  setup "[tools.node] table with version"
  bazzite
  dotfiles_fixture
  mise_node_fixture 20
  printf '[tools.node]\nversion = "20"\n' > "$HOME/.config/mise/config.toml"
  stub claude
  run_linux --dry-run
  check "recognised as installed" has "$OUT" 'node already installed via mise \(tools.node = 20 in '
  check "mise not run" log_lacks '^mise '
  teardown

  setup "node entry that cannot be parsed"
  bazzite
  dotfiles_fixture
  mise_node_fixture lts
  printf '[tools]\nnode = ["22", "20"]\n' > "$HOME/.config/mise/config.toml"
  conf_before="$(cat "$HOME/.config/mise/config.toml")"
  run_linux --dry-run
  check "dry run: never re-pins" lacks "$OUT" "\[dry-run\] .*mise use"
  check "dry run: plans mise install node" has "$OUT" "\[dry-run\] $STUBS/mise install node$"
  run_linux
  check "run never re-pins" log_lacks '^mise use'
  check "config unchanged" [ "$conf_before" = "$(cat "$HOME/.config/mise/config.toml")" ]
  teardown

  setup "config blocked, no npm anywhere"
  bazzite
  dotfiles_fixture
  ln -s Projects/Home/dotfiles/agy/.config "$HOME/.config"
  rm "$STUBS/npm"
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "skips Claude with a clear warning" has "$OUT" "skipped agent CLIs: no usable mise-managed Node"
  check "no npm call of any kind" log_lacks 'npm'
  check "no command-not-found noise" lacks "$OUT" "npm: command not found"
  teardown

  setup "reshim after the claude install fails"
  bazzite
  dotfiles_fixture
  STUB_RESHIM_RC=1 run_linux
  check "run completes" [ "$RC" -eq 0 ]
  check "claude was installed by npm" log_has '^mise-shim-npm install -g @anthropic-ai/claude-code$'
  check "warns claude has no shim" has "$OUT" "'mise reshim' failed after installing agent CLIs"
  check "no shim was made" [ ! -e "$HOME/.local/share/mise/shims/claude" ]
  teardown

  setup "mise use fails"
  bazzite
  dotfiles_fixture
  STUB_MISE_RC=1 run_linux
  check "run completes" [ "$RC" -eq 0 ]
  check "reports the failure" has "$OUT" "'mise use -g node@lts' failed"
  check "skips Claude" has "$OUT" "skipped agent CLIs"
  check "competing PATH npm never used" log_lacks '^npm '
  teardown

  setup "config path cannot be canonicalised"
  bazzite
  dotfiles_fixture
  stub realpath 'case "$*" in *config.toml*) exit 1 ;; esac; exec "$STUB_STATE/../sysbin/realpath" "$@"'
  run_linux --dry-run
  check "dry run: fails closed" has "$OUT" "could not resolve mise's global config"
  check "dry run: no mise use planned" lacks "$OUT" "\[dry-run\] .*mise use"
  run_linux
  check "run: fails closed" has "$OUT" "could not resolve mise's global config"
  check "run: mise use never ran" log_lacks '^mise use'
  check "run: no config written" [ ! -e "$HOME/.config/mise/config.toml" ]
  check "run: Claude skipped" has "$OUT" "skipped agent CLIs"
  teardown
}

# mise's global config is read with python3's tomllib. A node entry in any
# valid TOML form is a pin (never re-pinned); an unreadable config, or no way to
# parse it, is uncertain (never written, Node not installed).
pin_fixture() { # pin_fixture NAME TOML — the pin (20) differs from what is installed (22)
  setup "$1"
  bazzite
  dotfiles_fixture
  mise_node_fixture lts 22.12.0
  printf '%b' "$2" > "$HOME/.config/mise/config.toml"
  cp "$HOME/.config/mise/config.toml" "$SANDBOX/config.before"
}
same_config() { cmp -s "$SANDBOX/config.before" "$HOME/.config/mise/config.toml"; }

test_mise_config_parsing() {
  local name toml
  for name in quoted-table dotted-key multiline-fake-header; do
    case "$name" in
      quoted-table)          toml='["tools"]\nnode = "20"\n' ;;
      dotted-key)            toml='[tools]\nnode.version = "20"\n' ;;
      multiline-fake-header) toml='[env]\nBANNER = """\n[tools]\nnode = "lts"\n"""\n\n[tools.node]\nversion = "20"\n' ;;
    esac
    pin_fixture "pin 20 as $name" "$toml"
    run_linux --dry-run
    check "dry run: sees the pin (not installed: 22 only)" lacks "$OUT" "node already installed"
    check "dry run: no mise use planned" lacks "$OUT" "\[dry-run\] .*mise use"
    check "dry run: plans mise install node" has "$OUT" "\[dry-run\] $STUBS/mise install node$"
    check "dry run: mise not run" log_lacks '^mise '
    check "dry run: config byte-identical" same_config
    run_linux
    check "run exits 0" [ "$RC" -eq 0 ]
    check "run: never mise use" log_lacks '^mise use'
    check "run: installs the pinned 20" [ -x "$HOME/.local/share/mise/installs/node/20.18.1/bin/node" ]
    check "run: config byte-identical" same_config
    teardown
  done

  pin_fixture "node only inside a multiline string" '[env]\nBANNER = """\n[tools]\nnode = "20"\n"""\n'
  rm -rf "$HOME/.local/share/mise"
  run_linux --dry-run
  check "a string is not a pin: plans pinning lts" has "$OUT" "\[dry-run\] $STUBS/mise use -g node@lts$"
  teardown

  for name in invalid-toml no-python3 no-tomllib; do
    pin_fixture "uncertain config: $name" '[tools]\nnode = "20"\n'
    case "$name" in
      invalid-toml) printf '[tools\nnode = \n' > "$HOME/.config/mise/config.toml"
                    cp "$HOME/.config/mise/config.toml" "$SANDBOX/config.before" ;;
      no-python3)   rm "$SANDBOX/sysbin/python3" ;;
      # A real python3 whose `import tomllib` raises ImportError (as on 3.10).
      no-tomllib)   stub python3 'if [ "$1" = -I ] && [ "$2" = -c ]; then
  code="import sys; sys.modules[\"tomllib\"] = None
$3"; shift 3; exec "$STUB_STATE/../sysbin/python3" -I -c "$code" "$@"
fi
exec "$STUB_STATE/../sysbin/python3" "$@"' ;;
    esac
    run_linux --dry-run
    check "dry run: warns it can't tell" has "$OUT" "can't tell whether mise's global config .* pins node"
    case "$name" in
      invalid-toml) check "dry run: says it can't parse it" has "$OUT" "pins node \(cannot parse it: " ;;
      no-python3)   check "dry run: says python3 is missing" has "$OUT" "pins node \(python3 not found\)" ;;
      no-tomllib)   check "dry run: says tomllib is missing" has "$OUT" "pins node \(python3 has no tomllib" ;;
    esac
    check "dry run: no mise planned" lacks "$OUT" "\[dry-run\] .*mise (use|install)"
    check "dry run: config byte-identical" same_config
    run_linux
    check "run exits 0" [ "$RC" -eq 0 ]
    check "run: no mise use or install" log_lacks '^mise (use|install)'
    check "run: config byte-identical" same_config
    check "run: Claude skipped" has "$OUT" "skipped agent CLIs"
    check "run: no npm of any kind" log_lacks 'npm'
    teardown
  done
}

# The mise apt key is dearmored to a temp file, so a failed download or
# dearmor never leaves an empty keyring, and nothing after it runs.
test_mise_apt_failures() {
  local what
  for what in download dearmor; do
    setup "pop run (mise key $what fails)"
    os_release pop "ubuntu debian"
    dotfiles_fixture
    if [ "$what" = download ]; then
      STUB_CURL_FAIL=mise.jdx.dev/gpg-key.pub run_linux
      check "download was attempted" log_has '^curl -fsSL https://mise.jdx.dev/gpg-key.pub$'
    else
      STUB_GPG_RC=2 run_linux
      check "dearmor was attempted" log_has '^gpg --dearmor$'
    fi
    check "run fails" [ "$RC" -ne 0 ]
    check "no keyring installed" log_lacks '^sudo install -m 644 .*mise-archive-keyring'
    check "no mise apt source added" log_lacks 'mise\.list'
    check "mise not installed" log_lacks '^sudo apt-get install -y mise$'
    check "no mise, node or npm run" log_lacks '^mise|npm'
    check "no temp file left" [ -z "$(ls -A "$SANDBOX/tmp")" ]
    teardown
  done
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
  check "JDK 21 came from Homebrew" log_has '^brew install .* openjdk@21( |$)'
  check "mise came from Homebrew" log_has '^brew install .* mise( |$)'
  check "node lts pinned via mise, once" [ "$(log_count '^mise use -g node@lts$')" -eq 1 ]
  check "mise wrote its global config" [ "$(cat "$HOME/.config/mise/config.toml" 2>/dev/null)" = "$(printf '[tools]\nnode = "lts"')" ]
  check "node is installed under mise" [ -x "$HOME/.local/share/mise/installs/node/22.12.0/bin/node" ]
  check "fnm never involved" log_lacks '^fnm |fnm'
  check "claude installed through mise's npm shim, after node" logged_before '^mise use -g node@lts$' '^mise-shim-npm install -g @anthropic-ai/claude-code$'
  check "the shim ran the pinned node's npm" log_has '^mise-22.12.0-npm install -g @anthropic-ai/claude-code$'
  check "reshim after the claude install" logged_before '^mise-shim-npm install -g' '^mise reshim$'
  check "reshim exposed claude" [ -x "$HOME/.local/share/mise/shims/claude" ]
  check "PATH npm never used" log_lacks '^npm '

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
  check "re-run does not re-pin, install or reshim node" log_lacks '^mise (use|install|reshim)'
  check "re-run runs mise only for Playwright's own check" [ "$(log_count '^mise ')" -eq "$(log_count '^mise exec -- (npx playwright install chromium|node --version|npm list -g --depth=0 @salesforce/.*|sf plugins)$')" ]
  check "re-run reports node installed via mise" has "$OUT" "node already installed via mise"
  check "re-run leaves mise config unchanged" [ "$mise_conf_before" = "$(cat "$HOME/.config/mise/config.toml")" ]
  check "re-run finds claude, installs nothing with npm" log_lacks 'npm install'
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
  check "plans JDK 21 via apt" has "$OUT" "\[dry-run\] sudo apt-get install -y openjdk-21-jdk$"
  check "plans shellcheck via apt" has "$OUT" "\[dry-run\] sudo apt-get install -y shellcheck$"
  check "plans tmux via apt" has "$OUT" "\[dry-run\] sudo apt-get install -y tmux$"
  check "no gitleaks via apt (24.04's is older than 8.20.0)" lacks "$OUT" "apt-get install -y gitleaks"
  check "plans render-url npm ci through mise" has "$OUT" "\[dry-run\] \(cd $HOME/.local/share/render-url && mise exec -- npm ci\)$"
  check "plans chsh" has "$OUT" "\[dry-run\] chsh -s"
  check "stows tmux" has "$OUT" "\[dry-run\] stow .* --restow tmux$"
  check "never uses --adopt" lacks "$OUT" "--adopt"
  check "backs up instead of adopting" has "$OUT" "would back up ~/.bashrc"
  check "no brew / rpm-ostree" lacks "$OUT" "(brew install|rpm-ostree)"
  check "plans mise's apt signing key, 0644" has "$OUT" "\[dry-run\] .*curl -fsSL https://mise.jdx.dev/gpg-key.pub \| gpg --dearmor > \"\\\$tmp\" && sudo install -m 644 \"\\\$tmp\" /etc/apt/keyrings/mise-archive-keyring.gpg$"
  check "plans an apt-readable sources file" has "$OUT" "\[dry-run\] sudo chmod 644 /etc/apt/sources.list.d/mise.list$"
  check "plans claude through mise's npm shim" has "$OUT" "\[dry-run\] $HOME/.local/share/mise/shims/npm install -g @anthropic-ai/claude-code$"
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
  check "JDK 21 installed via apt" log_has '^sudo apt-get install -y openjdk-21-jdk$'
  check "mise installed from its apt repo" log_has '^sudo apt-get install -y mise$'
  check "apt repo written before the install" [ "$(grep -nE '^sudo (tee /etc/apt/sources.list.d/mise.list|apt-get install -y mise)' "$LOG" | cut -d: -f2- | tr '\n' '|')" = "sudo tee /etc/apt/sources.list.d/mise.list|sudo apt-get install -y mise|" ]
  check "node lts pinned via mise, once" [ "$(log_count '^mise use -g node@lts$')" -eq 1 ]
  check "mise wrote its global config" [ "$(cat "$HOME/.config/mise/config.toml" 2>/dev/null)" = "$(printf '[tools]\nnode = "lts"')" ]
  check "no fnm installer" log_lacks 'fnm'
  check "keyring installed 0644" log_has '^sudo install -m 644 .* /etc/apt/keyrings/mise-archive-keyring.gpg$'
  check "sources file made 0644" log_has '^sudo chmod 644 /etc/apt/sources.list.d/mise.list$'
  check "claude installed through mise's npm shim, after node" logged_before '^mise use -g node@lts$' '^mise-shim-npm install -g @anthropic-ai/claude-code$'
  check "reshim after the claude install" logged_before '^mise-shim-npm install -g' '^mise reshim$'
  check "reshim exposed claude" [ -x "$HOME/.local/share/mise/shims/claude" ]
  check "PATH npm never used" log_lacks '^npm '
  local conf_before; conf_before="$(cat "$HOME/.config/mise/config.toml")"
  : > "$LOG"
  run_linux
  check "re-run exits 0" [ "$RC" -eq 0 ]
  check "re-run skips JDK install" log_lacks '^sudo apt-get install -y openjdk-21-jdk$'
  check "re-run skips mise install" has "$OUT" "mise already installed"
  check "re-run adds no mise apt repo" log_lacks 'mise\.list|mise-archive-keyring|apt-get install -y mise'
  check "re-run does not re-pin, install or reshim node" log_lacks '^mise (use|install|reshim)'
  check "re-run runs mise only for Playwright's own check" [ "$(log_count '^mise ')" -eq "$(log_count '^mise exec -- (npx playwright install chromium|node --version|npm list -g --depth=0 @salesforce/.*|sf plugins)$')" ]
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
  check "dry run does not re-pin to lts" lacks "$OUT" "\[dry-run\] .*mise use"
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

# ── Tests: ~/.gitconfig identity and credentials ─────────────────────────────

GIT_EMAIL="me@example.test"

# An existing ~/.gitconfig as gh leaves it: identity, and per-host credential
# helpers whose first (empty) value resets any inherited helper.
user_gitconfig() {
  cat > "$HOME/.gitconfig" <<EOF
[user]
	name = Test User
	email = $GIT_EMAIL
	signingkey = ABC123
[core]
	editor = vim
[credential "https://github.com"]
	helper =
	helper = !gh auth git-credential
[credential "https://gist.github.com"]
	helper =
	helper = !gh auth git-credential
EOF
}

# Read ~/.gitconfig.local with the real git: every value of KEY, one per line.
local_get_all() { sandboxed "$STATE/real/git" config --file "$HOME/.gitconfig.local" --get-all "$1"; }

mode_600() { [ -n "$(find "$1" -maxdepth 0 -perm 0600 2>/dev/null)" ]; }

gitconfig_run() { # gitconfig_run PLATFORM(bazzite|pop)
  setup "$1 run: ~/.gitconfig identity/credentials carried to ~/.gitconfig.local"
  if [ "$1" = pop ]; then os_release pop "ubuntu debian"; else bazzite; fi
  dotfiles_fixture
  user_gitconfig
  local original; original="$(cat "$HOME/.gitconfig")"
  local helpers; helpers="$(printf '\n!gh auth git-credential')"
  run_linux
  check "exits 0" [ "$RC" -eq 0 ]
  check "creates ~/.gitconfig.local" [ -f "$HOME/.gitconfig.local" ]
  check "new ~/.gitconfig.local is mode 0600" mode_600 "$HOME/.gitconfig.local"
  check "user.name carried" [ "$(local_get_all user.name)" = "Test User" ]
  check "user.email carried" [ "$(local_get_all user.email)" = "$GIT_EMAIL" ]
  check "user.signingkey carried" [ "$(local_get_all user.signingkey)" = ABC123 ]
  check "github helpers carried in order, empty reset first" [ "$(local_get_all credential.https://github.com.helper)" = "$helpers" ]
  check "gist helpers carried in order, empty reset first" [ "$(local_get_all credential.https://gist.github.com.helper)" = "$helpers" ]
  check "other settings not carried" [ -z "$(local_get_all core.editor)" ]
  local backup; backup="$(find "$HOME/.local/state/laptop/backups" -name .gitconfig -type f 2>/dev/null | head -1)"
  check "old ~/.gitconfig backed up" [ -n "$backup" ]
  check "backup keeps the original content" [ "$(cat "${backup:-/nonexistent}" 2>/dev/null)" = "$original" ]
  check "new ~/.gitconfig links into dotfiles" [ "$(readlink "$HOME/.gitconfig")" = "$HOME/Projects/Home/dotfiles/git/.gitconfig" ]
  check "no git config --global writes (they would go into the repo)" log_lacks '^git config --global [^-]'
  check "says identity is set via ~/.gitconfig.local" has "$OUT" "git identity set via ~/.gitconfig.local"
  check "no identity warning" lacks "$OUT" "git identity is not set"
  check "never prints the email" lacks "$OUT" "$GIT_EMAIL"
  local local_before; local_before="$(cat "$HOME/.gitconfig.local")"
  : > "$LOG"
  run_linux
  check "re-run exits 0" [ "$RC" -eq 0 ]
  check "re-run leaves ~/.gitconfig.local unchanged" [ "$local_before" = "$(cat "$HOME/.gitconfig.local")" ]
  check "re-run writes nothing to it" log_lacks '^git config --file .* --add '
  check "re-run still reports identity" has "$OUT" "git identity set via ~/.gitconfig.local"
  teardown
}

test_gitconfig_carry_over() {
  gitconfig_run bazzite
  gitconfig_run pop
}

test_gitconfig_local_kept() {
  setup "existing ~/.gitconfig.local keys are never overwritten"
  bazzite
  dotfiles_fixture
  user_gitconfig
  printf '[user]\n\temail = keep@local.test\n[credential "https://github.com"]\n\thelper = keep\n' > "$HOME/.gitconfig.local"
  chmod 644 "$HOME/.gitconfig.local"
  run_linux
  check "exits 0" [ "$RC" -eq 0 ]
  check "existing user.email kept" [ "$(local_get_all user.email)" = keep@local.test ]
  check "existing github helper kept, nothing appended" [ "$(local_get_all credential.https://github.com.helper)" = keep ]
  check "missing user.name added" [ "$(local_get_all user.name)" = "Test User" ]
  check "missing gist helpers added" [ "$(local_get_all credential.https://gist.github.com.helper)" = "$(printf '\n!gh auth git-credential')" ]
  check "reports the kept key" has "$OUT" "kept existing user.email in ~/.gitconfig.local"
  check "rewritten file is mode 0600" mode_600 "$HOME/.gitconfig.local"
  teardown
}

test_gitconfig_missing_identity() {
  local mode
  for mode in --dry-run run; do
    setup "no identity anywhere ($mode)"
    bazzite
    dotfiles_fixture
    printf '[credential "https://github.com"]\n\thelper =\n\thelper = !gh auth git-credential\n' > "$HOME/.gitconfig"
    if [ "$mode" = run ]; then run_linux; else run_linux --dry-run; fi
    check "exits 0" [ "$RC" -eq 0 ]
    check "warns identity is missing" has "$OUT" "git identity is not set \(missing user.name user.email\)"
    check "warning is in the summary" has "$(sed -n '/==> Summary/,$p' <<<"$OUT")" "! git identity is not set"
    check "does not claim identity is set" lacks "$OUT" "identity (will be )?set via"
    teardown
  done

  setup "identity set by ~/.laptop.local"
  bazzite
  dotfiles_fixture
  printf 'git config --file ~/.gitconfig.local user.name "Local User"\ngit config --file ~/.gitconfig.local user.email "%s"\n' "$GIT_EMAIL" > "$HOME/.laptop.local"
  run_linux --dry-run
  check "dry-run: warning says ~/.laptop.local may set it" has "$OUT" "git identity is not set \(unless ~/.laptop.local sets it\)"
  run_linux
  check "exits 0" [ "$RC" -eq 0 ]
  check "identity checked after ~/.laptop.local ran" has "$OUT" "git identity set via ~/.gitconfig.local"
  check "no identity warning" lacks "$OUT" "git identity is not set"
  teardown

  setup "no ~/.gitconfig at all"
  bazzite
  dotfiles_fixture
  run_linux
  check "exits 0" [ "$RC" -eq 0 ]
  check "warns identity is missing" has "$OUT" "git identity is not set"
  check "no ~/.gitconfig.local created" [ ! -e "$HOME/.gitconfig.local" ]
  teardown
}

test_gitconfig_dry_run() {
  setup "dry-run: ~/.gitconfig carry-over is planned, nothing written"
  bazzite
  dotfiles_fixture
  user_gitconfig
  local before; before="$(home_snapshot)"
  run_linux --dry-run
  check "exits 0" [ "$RC" -eq 0 ]
  check "HOME is untouched" [ "$before" = "$(home_snapshot)" ]
  check "no ~/.gitconfig.local created" [ ! -e "$HOME/.gitconfig.local" ]
  check "no mutating command was executed" log_lacks "$MUTATING"
  check "plans user.name" has "$OUT" "would copy user.name to ~/.gitconfig.local \(1 value\)"
  check "plans user.email" has "$OUT" "would copy user.email to ~/.gitconfig.local"
  check "plans user.signingkey" has "$OUT" "would copy user.signingkey to ~/.gitconfig.local"
  check "plans both github helper values" has "$OUT" "would copy credential.https://github.com.helper to ~/.gitconfig.local \(2 values\)"
  check "plans gist helpers" has "$OUT" "would copy credential.https://gist.github.com.helper"
  check "does not plan other settings" lacks "$OUT" "would copy core"
  check "never prints the email" lacks "$OUT" "$GIT_EMAIL"
  check "plans the backup of ~/.gitconfig" has "$OUT" "would back up ~/.gitconfig "
  check "says identity will come from ~/.gitconfig.local" has "$OUT" "git identity will be set via ~/.gitconfig.local"
  check "no identity warning" lacks "$OUT" "git identity is not set"
  check "plans no git config --global" lacks "$OUT" "git config --global"
  teardown
}

test_gitconfig_unreadable() {
  setup "unreadable ~/.gitconfig stays put"
  bazzite
  dotfiles_fixture
  printf '[user\n\tname = broken\n' > "$HOME/.gitconfig"
  local original; original="$(cat "$HOME/.gitconfig")"
  run_linux
  check "exits 0" [ "$RC" -eq 0 ]
  check "leaves ~/.gitconfig in place" [ -f "$HOME/.gitconfig" ]
  check "is not replaced by a link" [ ! -L "$HOME/.gitconfig" ]
  check "keeps its content" [ "$(cat "$HOME/.gitconfig")" = "$original" ]
  check "git package skipped with a warning" has "$OUT" "skipped stowing git"
  check "explains why" has "$OUT" "could not read ~/.gitconfig"
  teardown
}

no_temp_left() { [ -z "$(find "$HOME" -maxdepth 1 -name '.gitconfig.local.*')" ]; }
not_stowed_git() { [ -f "$HOME/.gitconfig" ] && [ ! -L "$HOME/.gitconfig" ]; }

test_gitconfig_includes_refused() {
  local kind mode
  for kind in include includeIf; do
    for mode in --dry-run run; do
      setup "[$kind] in ~/.gitconfig: not migrated ($mode)"
      bazzite
      dotfiles_fixture
      user_gitconfig
      printf '[user]\n\tname = Work Name\n' > "$HOME/.gitconfig.work"
      if [ "$kind" = include ]; then
        printf '[include]\n\tpath = ~/.gitconfig.work\n' >> "$HOME/.gitconfig"
      else
        printf '[includeIf "gitdir:~/work/"]\n\tpath = ~/.gitconfig.work\n' >> "$HOME/.gitconfig"
      fi
      local original; original="$(cat "$HOME/.gitconfig")"
      if [ "$mode" = run ]; then run_linux; else run_linux --dry-run; fi
      check "exits 0" [ "$RC" -eq 0 ]
      check "explains the refusal" has "$OUT" "it uses \[include\]/\[includeIf\]"
      check "says what to do by hand" has "$OUT" "By hand: put user.name"
      check "git package skipped" has "$OUT" "skipped stowing git"
      check "copies nothing" lacks "$OUT" "(would )?cop(y|ied) (user|credential)"
      check "no ~/.gitconfig.local created" [ ! -e "$HOME/.gitconfig.local" ]
      check "leaves ~/.gitconfig as a file" not_stowed_git
      check "keeps its content" [ "$(cat "$HOME/.gitconfig")" = "$original" ]
      check "plans no backup of it" lacks "$OUT" "back(ed)? up ~/.gitconfig"
      teardown
    done
  done
}

test_gitconfig_write_failure_retry() {
  local helpers; helpers="$(printf '\n!gh auth git-credential')"
  setup "write fails mid-migration, then retry (no ~/.gitconfig.local)"
  bazzite
  dotfiles_fixture
  user_gitconfig
  local original; original="$(cat "$HOME/.gitconfig")"
  STUB_GIT_FAIL='helper !gh auth' run_linux
  check "exits 0" [ "$RC" -eq 0 ]
  check "warns the write failed" has "$OUT" "could not write ~/.gitconfig.local \(left unchanged\)"
  check "no partial ~/.gitconfig.local" [ ! -e "$HOME/.gitconfig.local" ]
  check "no temp file left" no_temp_left
  check "keeps ~/.gitconfig as a file" not_stowed_git
  check "keeps ~/.gitconfig content" [ "$(cat "$HOME/.gitconfig")" = "$original" ]
  check "git package skipped" has "$OUT" "skipped stowing git"
  run_linux
  check "retry exits 0" [ "$RC" -eq 0 ]
  check "retry keeps gh auth (both helper values)" [ "$(local_get_all credential.https://github.com.helper)" = "$helpers" ]
  check "retry keeps gist gh auth" [ "$(local_get_all credential.https://gist.github.com.helper)" = "$helpers" ]
  check "retry carries user.name" [ "$(local_get_all user.name)" = "Test User" ]
  check "retry stows git" [ -L "$HOME/.gitconfig" ]
  check "retry leaves no temp file" no_temp_left
  teardown

  setup "write fails mid-migration, then retry (existing ~/.gitconfig.local)"
  bazzite
  dotfiles_fixture
  user_gitconfig
  printf '[user]\n\temail = keep@local.test\n' > "$HOME/.gitconfig.local"
  chmod 644 "$HOME/.gitconfig.local"
  local before; before="$(cat "$HOME/.gitconfig.local"; ls -l "$HOME/.gitconfig.local")"
  STUB_GIT_FAIL='helper !gh auth' run_linux
  check "existing ~/.gitconfig.local byte-identical, same mode" [ "$before" = "$(cat "$HOME/.gitconfig.local"; ls -l "$HOME/.gitconfig.local")" ]
  check "no temp file left" no_temp_left
  run_linux
  check "retry keeps gh auth (both helper values)" [ "$(local_get_all credential.https://github.com.helper)" = "$helpers" ]
  check "retry keeps the existing email" [ "$(local_get_all user.email)" = keep@local.test ]
  teardown

  setup "verification of the new ~/.gitconfig.local fails"
  bazzite
  dotfiles_fixture
  user_gitconfig
  STUB_GIT_FAIL='--null --get-all' run_linux
  check "warns the write failed" has "$OUT" "could not write ~/.gitconfig.local \(left unchanged\)"
  check "unverified file not moved into place" [ ! -e "$HOME/.gitconfig.local" ]
  check "no temp file left" no_temp_left
  check "keeps ~/.gitconfig as a file" not_stowed_git
  teardown
}

test_gitconfig_local_not_regular() {
  setup "symlinked ~/.gitconfig.local is refused"
  bazzite
  dotfiles_fixture
  user_gitconfig
  local target="$HOME/Projects/Home/dotfiles/git/local.example"
  printf '[core]\n\teditor = nano\n' > "$target"
  ln -s "$target" "$HOME/.gitconfig.local"
  local target_before; target_before="$(cat "$target")"
  run_linux
  check "exits 0" [ "$RC" -eq 0 ]
  check "explains the refusal" has "$OUT" "not writing through ~/.gitconfig.local: it is a symlink or not a regular file"
  check "link target unchanged" [ "$(cat "$target")" = "$target_before" ]
  check "link left as is" [ "$(readlink "$HOME/.gitconfig.local")" = "$target" ]
  check "keeps ~/.gitconfig as a file" not_stowed_git
  check "git package skipped" has "$OUT" "skipped stowing git"
  teardown

  setup "directory at ~/.gitconfig.local is refused"
  bazzite
  dotfiles_fixture
  user_gitconfig
  mkdir "$HOME/.gitconfig.local"
  run_linux
  check "explains the refusal" has "$OUT" "not writing through ~/.gitconfig.local"
  check "directory left empty" [ -z "$(ls -A "$HOME/.gitconfig.local")" ]
  check "keeps ~/.gitconfig as a file" not_stowed_git
  teardown
}

test_gitconfig_identity_final() {
  local what cmd
  for what in empty unset; do
    if [ "$what" = empty ]; then cmd='git config --file ~/.gitconfig.local user.email ""'; else cmd='git config --file ~/.gitconfig.local --unset user.email'; fi
    setup "identity carried, then $what by ~/.laptop.local"
    bazzite
    dotfiles_fixture
    user_gitconfig
    echo "$cmd" > "$HOME/.laptop.local"
    run_linux
    check "exits 0" [ "$RC" -eq 0 ]
    check "email really is $what now" [ -z "$(local_get_all user.email)" ]
    check "warns user.email is missing" has "$OUT" "git identity is not set \(missing user.email\)"
    check "does not claim identity is set" lacks "$OUT" "identity (will be )?set via"
    teardown
  done
}

test_gitconfig_bare_key() {
  setup "bare (valueless) credential key is refused, not turned into true"
  bazzite
  dotfiles_fixture
  user_gitconfig
  printf '[credential]\n\tuseHttpPath\n' >> "$HOME/.gitconfig"
  run_linux
  check "exits 0" [ "$RC" -eq 0 ]
  check "explains the refusal" has "$OUT" "credential.usehttppath in ~/.gitconfig has no value"
  check "no ~/.gitconfig.local written" [ ! -e "$HOME/.gitconfig.local" ]
  check "keeps ~/.gitconfig as a file" not_stowed_git
  teardown
}

test_global_config_not_written_into_repo() {
  setup "no git config --global when ~/.config/git/config links into the repo"
  bazzite
  dotfiles_fixture
  local d="$HOME/Projects/Home/dotfiles"
  rm -rf "$d/git"
  mkdir -p "$d/misc" "$HOME/.config/git"
  echo "[core]" > "$d/misc/gitconfig"
  ln -s "$d/misc/gitconfig" "$HOME/.config/git/config"
  run_linux
  check "exits 0" [ "$RC" -eq 0 ]
  check "git package was not stowed" has "$OUT" "dotfiles has no 'git' package"
  check "no git config --global writes" log_lacks '^git config --global [^-]'
  check "repo file unchanged" [ "$(cat "$d/misc/gitconfig")" = "[core]" ]
  teardown
}

test_git_stub_sandbox() {
  setup "git stub refuses --file outside HOME"
  mkdir -p "$SANDBOX/outside"
  printf '[user]\n\tname = x\n' > "$SANDBOX/outside/cfg"
  printf '[user]\n\tname = x\n' > "$HOME/cfg"
  ln -s "$SANDBOX/outside" "$HOME/esc"
  sandboxed "$STUBS/git" config --file "$HOME/../outside/cfg" --list >/dev/null 2>&1
  check "refuses a .. escape" [ $? -eq 98 ]
  sandboxed "$STUBS/git" config --file "$HOME/esc/cfg" --list >/dev/null 2>&1
  check "refuses a symlink escape" [ $? -eq 98 ]
  sandboxed "$STUBS/git" config --file "$HOME/cfg" --list >/dev/null 2>&1
  check "allows a file inside HOME" [ $? -eq 0 ]
  teardown
}

test_gitconfig_local_includes_refused() {
  local kind mode
  for kind in include includeIf; do
    for mode in --dry-run run; do
      setup "[$kind] in existing ~/.gitconfig.local: not migrated ($mode)"
      bazzite
      dotfiles_fixture
      user_gitconfig
      printf '[user]\n\temail = creds@local.test\n' > "$HOME/.gitconfig.creds"
      if [ "$kind" = include ]; then
        printf '[include]\n\tpath = ~/.gitconfig.creds\n' > "$HOME/.gitconfig.local"
      else
        printf '[includeIf "gitdir:~/work/"]\n\tpath = ~/.gitconfig.creds\n' > "$HOME/.gitconfig.local"
      fi
      local before; before="$(cat "$HOME/.gitconfig.local")"
      if [ "$mode" = run ]; then run_linux; else run_linux --dry-run; fi
      check "exits 0" [ "$RC" -eq 0 ]
      check "explains the refusal" has "$OUT" "not copying into ~/.gitconfig.local: it uses \[include\]/\[includeIf\]"
      check "copies nothing" lacks "$OUT" "(would )?cop(y|ied) (user|credential)"
      check "leaves ~/.gitconfig.local unchanged" [ "$(cat "$HOME/.gitconfig.local")" = "$before" ]
      check "keeps ~/.gitconfig as a file" not_stowed_git
      check "git package skipped" has "$OUT" "skipped stowing git"
      teardown
    done
  done
}

test_gitconfig_listing_failure() {
  local how
  for how in STUB_GIT_FAIL STUB_GIT_TRUNC; do
    setup "listing ~/.gitconfig fails ($how)"
    bazzite
    dotfiles_fixture
    user_gitconfig
    local original; original="$(cat "$HOME/.gitconfig")"
    if [ "$how" = STUB_GIT_FAIL ]; then STUB_GIT_FAIL='--null --list' run_linux; else STUB_GIT_TRUNC='--null --list' run_linux; fi
    check "exits 0" [ "$RC" -eq 0 ]
    check "explains the refusal" has "$OUT" "could not list the settings in ~/.gitconfig"
    check "no ~/.gitconfig.local written" [ ! -e "$HOME/.gitconfig.local" ]
    check "keeps ~/.gitconfig as a file" not_stowed_git
    check "keeps ~/.gitconfig content" [ "$(cat "$HOME/.gitconfig")" = "$original" ]
    check "not backed up" lacks "$OUT" "backed up ~/.gitconfig"
    teardown
  done
}

test_gitconfig_rename_race() {
  setup "rename race: ~/.gitconfig.local becomes a dir symlink"
  bazzite
  dotfiles_fixture
  user_gitconfig
  mkdir -p "$HOME/victim"
  STUB_GIT_ON='--null --get-all' STUB_GIT_DO='[ -e "$HOME/.gitconfig.local" ] || ln -s "$HOME/victim" "$HOME/.gitconfig.local"' run_linux
  check "exits 0" [ "$RC" -eq 0 ]
  check "nothing written into the link's target dir" [ -z "$(ls -A "$HOME/victim")" ]
  check "the link is left as is" [ "$(readlink "$HOME/.gitconfig.local")" = "$HOME/victim" ]
  check "no temp file left" no_temp_left
  check "warns the write failed" has "$OUT" "could not write ~/.gitconfig.local \(left unchanged\)"
  check "keeps ~/.gitconfig as a file" not_stowed_git
  teardown
}

test_gitconfig_interrupted() {
  setup "migration killed (TERM) while writing the temp file"
  bazzite
  dotfiles_fixture
  user_gitconfig
  local original; original="$(cat "$HOME/.gitconfig")"
  STUB_GIT_ON='--add' STUB_GIT_DO='kill -TERM $PPID' run_linux
  check "exits 143" [ "$RC" -eq 143 ]
  check "temp file removed by the trap" no_temp_left
  check "no ~/.gitconfig.local written" [ ! -e "$HOME/.gitconfig.local" ]
  check "keeps ~/.gitconfig content" [ "$(cat "$HOME/.gitconfig")" = "$original" ]
  teardown
}

test_gitconfig_xdg_identity() {
  local mode
  for mode in --dry-run run; do
    setup "identity only in ~/.config/git/config ($mode)"
    bazzite
    dotfiles_fixture
    mkdir -p "$HOME/.config/git"
    printf '[user]\n\tname = Xdg User\n\temail = xdg@example.test\n' > "$HOME/.config/git/config"
    if [ "$mode" = run ]; then run_linux; else run_linux --dry-run; fi
    check "exits 0" [ "$RC" -eq 0 ]
    check "no false missing-identity warning" lacks "$OUT" "git identity is not set"
    check "reports it from the global git config" has "$OUT" "git identity (will be )?set via the global git config"
    teardown
  done

  setup "XDG email, but ~/.gitconfig.local sets it empty"
  bazzite
  dotfiles_fixture
  mkdir -p "$HOME/.config/git"
  printf '[user]\n\tname = Xdg User\n\temail = xdg@example.test\n' > "$HOME/.config/git/config"
  printf '[user]\n\temail =\n' > "$HOME/.gitconfig.local"
  run_linux
  check "empty effective email still counts as missing" has "$OUT" "git identity is not set \(missing user.email\)"
  teardown
}

test_git_stub_includes() {
  setup "git stub refuses includes that leave HOME"
  mkdir -p "$SANDBOX/outside"
  printf '[user]\n\tname = x\n' > "$SANDBOX/outside/cfg"
  ln -s "$SANDBOX/outside" "$HOME/esc"
  printf '[user]\n\tname = in\n' > "$HOME/in.cfg"
  printf '[include]\n\tpath = %s\n' "$SANDBOX/outside/cfg" > "$HOME/abs.cfg"
  printf '[include]\n\tpath = ../outside/cfg\n' > "$HOME/rel.cfg"
  printf '[includeIf "gitdir:~/"]\n\tpath = ~/esc/cfg\n' > "$HOME/link.cfg"
  printf '[include]\n\tpath = ~/rel.cfg\n' > "$HOME/nested.cfg"
  printf '[include]\n\tpath = ~/in.cfg\n' > "$HOME/ok.cfg"
  local f rc
  for f in abs rel link nested; do
    sandboxed "$STUBS/git" config --file "$HOME/$f.cfg" --includes --get user.name >/dev/null 2>&1; rc=$?
    check "refuses --includes with a $f escape" [ "$rc" -eq 98 ]
  done
  cp "$HOME/abs.cfg" "$HOME/.gitconfig"
  sandboxed "$STUBS/git" config --global --includes --get user.name >/dev/null 2>&1; rc=$?
  check "refuses --global --includes with an escape in ~/.gitconfig" [ "$rc" -eq 98 ]
  sandboxed "$STUBS/git" config --file "$HOME/ok.cfg" --includes --get user.name >/dev/null 2>&1; rc=$?
  check "allows includes inside HOME" [ "$rc" -eq 0 ]
  sandboxed "$STUBS/git" config --file "$HOME/abs.cfg" --list >/dev/null 2>&1; rc=$?
  check "allows reading without following includes" [ "$rc" -eq 0 ]
  teardown
}

# ── Tests: font detection ────────────────────────────────────────────────────

test_font_detection() {
  setup "font known to fontconfig, long fc-list output (SIGPIPE)"
  bazzite
  dotfiles_fixture
  stub fc-list 'echo "/x/JetBrainsMonoNerdFont-Regular.ttf: JetBrainsMono Nerd Font:style=Regular"
for ((i = 0; i < 50000; i++)); do echo "/usr/share/fonts/f$i.ttf: Some Other Font:style=Regular"; done'
  run_linux --dry-run
  check "reports the font installed" has "$OUT" "JetBrains Mono Nerd Font already installed"
  check "plans no download" lacks "$OUT" "nerd-fonts"
  check "no network" log_lacks '^curl'
  teardown

  setup "font files in ~/.local/share/fonts, fontconfig silent"
  bazzite
  dotfiles_fixture
  stub fc-list 'exit 0'
  mkdir -p "$HOME/.local/share/fonts/JetBrainsMono"
  touch "$HOME/.local/share/fonts/JetBrainsMono/JetBrainsMonoNerdFont-Regular.ttf"
  run_linux --dry-run
  check "reports the font installed" has "$OUT" "JetBrains Mono Nerd Font already installed"
  check "plans no download" lacks "$OUT" "nerd-fonts"
  teardown

  setup "font files present, no fc-list"
  bazzite
  dotfiles_fixture
  rm -f "$STUBS/fc-list"
  mkdir -p "$HOME/.local/share/fonts/JetBrainsMono"
  touch "$HOME/.local/share/fonts/JetBrainsMono/JetBrainsMonoNerdFont-Bold.ttf"
  run_linux --dry-run
  check "reports the font installed" has "$OUT" "JetBrains Mono Nerd Font already installed"
  teardown

  setup "font absent"
  bazzite
  dotfiles_fixture
  stub fc-list 'echo "/x/DejaVuSans.ttf: DejaVu Sans:style=Book"'
  run_linux --dry-run
  check "plans the download" has "$OUT" "\[dry-run\] tmp=.*nerd-fonts/releases/latest/download/JetBrainsMono.zip"
  check "dry-run hits no network" log_lacks '^curl'
  teardown
}


# Stateful fake gsettings: all state is JSON inside the guarded sandbox.
terminal_fixture() {
  dotfiles_fixture
  all_done_fixture
  stub ghostty
  mkdir -p "$HOME/Projects/Home/dotfiles/xdg/.config"
  echo com.mitchellh.ghostty.desktop > "$HOME/Projects/Home/dotfiles/xdg/.config/xdg-terminals.list"
  echo '{}' > "$STATE/gsettings.json"
  cat > "$STATE/gsettings.py" <<'EOF'
import ast, json, os, sys
from pathlib import Path
f = Path(os.environ['STUB_STATE']) / 'gsettings.json'
d = json.loads(f.read_text())
a = sys.argv[1:]
schema = 'org.gnome.settings-daemon.plugins.media-keys'
if a == ['list-schemas']:
    print(schema)
elif a == ['list-relocatable-schemas']:
    print(schema + '.custom-keybinding')
elif a[0] == 'get':
    value = d.get(a[1] + ' ' + a[2], [] if a[2] == 'custom-keybindings' else '')
    print(repr(value) if value != [] else '@as []')
elif a[0] == 'set':
    d[a[1] + ' ' + a[2]] = ast.literal_eval(a[3])
    f.write_text(json.dumps(d, sort_keys=True))
else:
    raise AssertionError(a)
EOF
  stub gsettings 'exec python3 "$STUB_STATE/gsettings.py" "$@"'
}

test_default_terminal() {
  local schema=org.gnome.settings-daemon.plugins.media-keys
  local base=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
  local custom="$schema.custom-keybinding" before state backups
  setup "Ghostty replaces existing Ctrl+Alt+T, preserving other bindings"
  bazzite
  terminal_fixture
  sandboxed "$STUBS/gsettings" set "$schema" custom-keybindings "['$base/custom0/', '$base/custom7/']"
  sandboxed "$STUBS/gsettings" set "$custom:$base/custom0/" binding "'<Super>e'"
  sandboxed "$STUBS/gsettings" set "$custom:$base/custom0/" command "'nautilus'"
  sandboxed "$STUBS/gsettings" set "$custom:$base/custom7/" binding "'<Control><Alt>t'"
  sandboxed "$STUBS/gsettings" set "$custom:$base/custom7/" command "'ptyxis --new-window'"
  echo com.mitchellh.ghostty.desktop > "$HOME/.config/xdg-terminals.list"
  before="$(home_snapshot)"; state="$(cat "$STATE/gsettings.json")"; : > "$LOG"
  XDG_CURRENT_DESKTOP=ubuntu:GNOME run_linux --dry-run
  check "dry run succeeds" [ "$RC" -eq 0 ]
  check "plans stow without folding" has "$OUT" 'stow --no-folding .* --restow xdg'
  check "plans existing shortcut update" has "$OUT" 'custom7/ command.*ghostty --gtk-single-instance=true'
  check "dry run home unchanged" [ "$before" = "$(home_snapshot)" ]
  check "dry run settings unchanged" [ "$state" = "$(cat "$STATE/gsettings.json")" ]
  check "dry run never mutates" log_lacks "$MUTATING"
  XDG_CURRENT_DESKTOP=GNOME run_linux
  check "run succeeds" [ "$RC" -eq 0 ]
  check "preference symlink installed" [ -L "$HOME/.config/xdg-terminals.list" ]
  check "config remains real directory" is_real_dir "$HOME/.config"
  backups="$(find "$HOME/.local/state/laptop/backups" -name xdg-terminals.list -type f)"
  check "identical regular file backed up" [ -n "$backups" ]
  check "backup contents preserved" [ "$(cat "$backups")" = com.mitchellh.ghostty.desktop ]
  check "only matching shortcut updated" [ "$(grep -c '^gsettings set' "$LOG")" -eq 1 ]
  check "unrelated command preserved" [ "$(sandboxed "$STUBS/gsettings" get "$custom:$base/custom0/" command)" = "'nautilus'" ]
  check "binding list preserved" [ "$(sandboxed "$STUBS/gsettings" get "$schema" custom-keybindings)" = "['$base/custom0/', '$base/custom7/']" ]
  check "correct shortcut updated" log_has 'custom7/ command.*ghostty --gtk-single-instance=true'
  state="$(cat "$STATE/gsettings.json")"; : > "$LOG"
  XDG_CURRENT_DESKTOP=GNOME run_linux
  check "rerun succeeds" [ "$RC" -eq 0 ]
  check "rerun settings unchanged" [ "$state" = "$(cat "$STATE/gsettings.json")" ]
  check "rerun writes no settings" log_lacks '^gsettings set'
  check "rerun creates no backups" lacks "$OUT" 'Backed up \('
  teardown

  local existing
  for existing in empty occupied; do
    setup "new terminal shortcut: $existing"
    bazzite; terminal_fixture
    if [ "$existing" = occupied ]; then
      sandboxed "$STUBS/gsettings" set "$schema" custom-keybindings "['$base/custom0/']"
      sandboxed "$STUBS/gsettings" set "$custom:$base/custom0/" binding "'<Super>e'"
    fi
    : > "$LOG"
    before="$(home_snapshot)"; state="$(cat "$STATE/gsettings.json")"
    XDG_CURRENT_DESKTOP=GNOME run_linux --dry-run
    check "creation dry run succeeds" [ "$RC" -eq 0 ]
    check "creation dry run home unchanged" [ "$before" = "$(home_snapshot)" ]
    check "creation dry run settings unchanged" [ "$state" = "$(cat "$STATE/gsettings.json")" ]
    check "creation dry run never mutates" log_lacks "$MUTATING"
    check "creation dry run prints list update" has "$OUT" 'gsettings set .* custom-keybindings '
    XDG_CURRENT_DESKTOP=GNOME run_linux
    check "creation succeeds" [ "$RC" -eq 0 ]
    if [ "$existing" = occupied ]; then
      check "appends without clobbering" log_has "custom-keybindings .*custom0/.*custom1/"
      check "uses free slot" log_has 'custom1/ command.*ghostty'
    else
      check "starts with custom0" log_has 'custom0/ command.*ghostty'
    fi
    state="$(cat "$STATE/gsettings.json")"; : > "$LOG"
    XDG_CURRENT_DESKTOP=GNOME run_linux
    check "creation rerun is idempotent" [ "$state" = "$(cat "$STATE/gsettings.json")" ]
    check "creation rerun has no writes" log_lacks '^gsettings set'
    teardown
  done
}

test_default_terminal_skips() {
  local scenario desktop
  for scenario in kde absent_desktop missing_ghostty missing_gsettings missing_schema bad_list debian fedora; do
    setup "default terminal skip: $scenario"
    bazzite; terminal_fixture; desktop=GNOME
    case "$scenario" in
      kde) desktop=KDE ;;
      absent_desktop) desktop= ;;
      missing_ghostty) rm "$STUBS/ghostty" ;;
      missing_gsettings) rm "$STUBS/gsettings" ;;
      missing_schema) stub gsettings 'exit 0' ;;
      bad_list) stub gsettings 'case "$1" in list-schemas) echo org.gnome.settings-daemon.plugins.media-keys ;; list-relocatable-schemas) echo org.gnome.settings-daemon.plugins.media-keys.custom-keybinding ;; get) echo invalid ;; esac' ;;
      debian) os_release pop ubuntu ;;
      fedora) os_release fedora ;;
    esac
    : > "$LOG"
    XDG_CURRENT_DESKTOP="$desktop" run_linux
    check "skip succeeds ($scenario)" [ "$RC" -eq 0 ]
    check "no settings writes ($scenario)" log_lacks '^gsettings set'
    case "$scenario" in
      missing_gsettings|missing_schema|bad_list) check "notice ($scenario)" has "$OUT" 'skipped terminal shortcut' ;;
      *) check "no xdg stow ($scenario)" log_lacks '^stow .* xdg$' ;;
    esac
    teardown
  done
}

# ── Tests: render-url and the applications package ──────────────────────────

RU_DIR_REL=.local/share/render-url
ru_log() { log_count "^mise exec -- $1"; }

test_render_url() {
  local ru before repo_before pw
  setup "render-url: bazzite dry-run (fresh)"
  bazzite
  dotfiles_fixture
  ru="$HOME/$RU_DIR_REL"
  before="$(home_snapshot)"
  run_linux --dry-run
  check "exits 0" [ "$RC" -eq 0 ]
  check "stows render-url without folding" has "$OUT" '\[dry-run\] stow --no-folding .* --restow render-url$'
  check "stows applications without folding" has "$OUT" '\[dry-run\] stow --no-folding .* --restow applications$'
  check "folds other packages as before" has "$OUT" '\[dry-run\] stow --dir=.* --restow tmux$'
  check "plans npm ci through mise exec" has "$OUT" "\[dry-run\] \(cd $ru && mise exec -- npm ci\)$"
  check "plans the documented browser install" has "$OUT" "\[dry-run\] \(cd $ru && mise exec -- npx playwright install chromium\)$"
  check "npm ci planned after stowing render-url" [ "$(grep -n -m1 'restow render-url$' <<<"$OUT" | cut -d: -f1)" -lt "$(grep -n -m1 'npm ci' <<<"$OUT" | cut -d: -f1)" ]
  check "no mutating command was executed" log_lacks "$MUTATING"
  check "HOME is untouched" [ "$before" = "$(home_snapshot)" ]
  teardown

  setup "render-url: bazzite run + re-run (stubbed)"
  bazzite
  dotfiles_fixture
  ru="$HOME/$RU_DIR_REL"
  repo_before="$(repo_snapshot)"
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "brew installed the new formulae" log_has '^brew install .* lazygit tree-sitter-cli shellcheck markdownlint-cli2( |$)'
  check "render-url dir is a real dir" is_real_dir "$ru"
  check "render-url script is stowed" [ "$(realpath "$ru/render-url.mjs")" = "$(realpath "$HOME/Projects/Home/dotfiles/render-url/$RU_DIR_REL/render-url.mjs")" ]
  check ".local/bin stays a real dir" is_real_dir "$HOME/.local/bin"
  check ".local/share/applications stays a real dir" is_real_dir "$HOME/.local/share/applications"
  check "claude-on-mac.desktop is stowed" [ -L "$HOME/.local/share/applications/claude-on-mac.desktop" ]
  check "claude-on-mac is stowed" [ -L "$HOME/.local/bin/claude-on-mac" ]
  check "npm ci ran once through mise exec" [ "$(ru_log 'npm ci$')" -eq 1 ]
  check "mise exec ran the pinned node's npm" log_has '^mise-22.12.0-npm ci$'
  check "npm ci after node was pinned" logged_before '^mise use -g node@lts$' '^mise exec -- npm ci$'
  check "browser install after npm ci" logged_before '^mise exec -- npm ci$' '^mise exec -- npx playwright install chromium$'
  check "the pinned node's npx installed Chromium" log_has '^mise-22.12.0-npx playwright install chromium$'
  check "node_modules is beside the stowed files" [ -d "$ru/node_modules/playwright" ]
  check "lockfile hash recorded" [ "$(cat "$ru/node_modules/.laptop-package-lock.sha256")" = "$(sha256sum < "$ru/package-lock.json")" ]
  check "PATH npm never used" log_lacks '^npm '
  check "nothing written into the repo" [ "$repo_before" = "$(repo_snapshot)" ]
  : > "$LOG"
  run_linux
  check "re-run exits 0" [ "$RC" -eq 0 ]
  check "re-run skips npm ci" [ "$(ru_log 'npm ci$')" -eq 0 ]
  check "re-run says deps are installed" has "$OUT" "render-url dependencies already installed"
  check "re-run still asks Playwright" [ "$(ru_log 'npx playwright install chromium$')" -eq 1 ]
  check "re-run downloads nothing (Playwright has its build)" [ "$(wc -l < "$STATE/pw-downloads")" -eq 2 ]
  check "re-run has no stow failures" lacks "$OUT" "stow failed"

  : > "$LOG"
  echo '{"lockfileVersion":3,"changed":true}' > "$HOME/Projects/Home/dotfiles/render-url/$RU_DIR_REL/package-lock.json"
  run_linux
  check "changed lockfile: npm ci again" [ "$(ru_log 'npm ci$')" -eq 1 ]
  check "changed lockfile: browser install re-checked" [ "$(ru_log 'npx playwright install chromium$')" -eq 1 ]
  check "changed lockfile: new hash recorded" [ "$(cat "$ru/node_modules/.laptop-package-lock.sha256")" = "$(sha256sum < "$ru/package-lock.json")" ]

  : > "$LOG"
  rm -rf "$HOME/.cache/ms-playwright"
  run_linux
  check "browser missing: no npm ci" [ "$(ru_log 'npm ci$')" -eq 0 ]
  check "browser missing: installs Chromium" [ "$(ru_log 'npx playwright install chromium$')" -eq 1 ]
  teardown

  setup "render-url: dry-run when everything is in place"
  bazzite
  dotfiles_fixture
  all_done_fixture
  before="$(home_snapshot)"
  run_linux --dry-run
  check "exits 0" [ "$RC" -eq 0 ]
  check "says deps are installed" has "$OUT" "render-url dependencies already installed"
  check "plans no npm ci" lacks "$OUT" "npm ci"
  check "still plans Playwright's own check" has "$OUT" "\[dry-run\] \(cd .* && .*mise exec -- npx playwright install chromium\)$"
  check "HOME is untouched" [ "$before" = "$(home_snapshot)" ]
  teardown

  setup "render-url: an older cached Chromium"
  bazzite
  dotfiles_fixture
  all_done_fixture
  pw="$HOME/.cache/ms-playwright"
  rm -rf "$pw"; mkdir -p "$pw/chromium-1100" "$pw/chromium_headless_shell-1100"
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "install still invoked" [ "$(ru_log 'npx playwright install chromium$')" -eq 1 ]
  check "the required revision was fetched" is_real_dir "$pw/chromium-1140"
  check "no npm ci" [ "$(ru_log 'npm ci$')" -eq 0 ]
  teardown

  setup "render-url: headless shell missing"
  bazzite
  dotfiles_fixture
  all_done_fixture
  pw="$HOME/.cache/ms-playwright"
  rm -rf "$pw/chromium_headless_shell-1140"
  run_linux
  check "install invoked" [ "$(ru_log 'npx playwright install chromium$')" -eq 1 ]
  check "only the headless shell was downloaded" [ "$(cat "$STATE/pw-downloads")" = chromium_headless_shell-1140 ]
  teardown

  setup "render-url: browser install fails, then the re-run"
  bazzite
  dotfiles_fixture
  mkdir -p "$HOME/.cache/ms-playwright/chromium-1100"   # an old build must not count
  STUB_PW_RC=1 run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "warns about the failure" has "$OUT" "'npx playwright install chromium' failed.*retried on the next run"
  check "npm ci's stamp was still recorded" [ -s "$HOME/$RU_DIR_REL/node_modules/.laptop-package-lock.sha256" ]
  : > "$LOG"
  STUB_PW_RC=1 run_linux
  check "second failing run retries the install" [ "$(ru_log 'npx playwright install chromium$')" -eq 1 ]
  check "does not claim Chromium is installed" lacks "$OUT" "Playwright Chromium .*is installed"
  : > "$LOG"
  run_linux
  check "re-run retries the install" [ "$(ru_log 'npx playwright install chromium$')" -eq 1 ]
  check "re-run does not repeat npm ci" [ "$(ru_log 'npm ci$')" -eq 0 ]
  check "re-run fetched the required build" is_real_dir "$HOME/.cache/ms-playwright/chromium_headless_shell-1140"
  teardown

  setup "render-url: no usable mise Node"
  bazzite
  dotfiles_fixture
  STUB_MISE_RC=1 run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "warns and skips" has "$OUT" "skipped render-url dependencies: no usable mise-managed Node"
  check "never runs npm" log_lacks '^mise exec -- (npm ci|npx)|^npm |-npm ci'
  check "no node_modules" [ ! -e "$HOME/$RU_DIR_REL/node_modules" ]
  teardown

  setup "render-url: npm ci fails"
  bazzite
  dotfiles_fixture
  STUB_NPM_CI_RC=1 run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "warns about the failure" has "$OUT" "'mise exec -- npm ci' failed"
  check "no browser install after a failed npm ci" log_lacks 'playwright install'
  check "no hash recorded" [ ! -e "$HOME/$RU_DIR_REL/node_modules/.laptop-package-lock.sha256" ]
  : > "$LOG"
  run_linux
  check "re-run retries npm ci" [ "$(ru_log 'npm ci$')" -eq 1 ]
  check "re-run then installs Chromium" [ "$(ru_log 'npx playwright install chromium$')" -eq 1 ]
  teardown

  setup "render-url: folded into the repo by an earlier stow"
  bazzite
  dotfiles_fixture
  mkdir -p "$HOME/.local/share"
  ln -s ../../Projects/Home/dotfiles/render-url/.local/share/render-url "$HOME/.local/share/render-url"
  repo_before="$(repo_snapshot)"
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "restow --no-folding unfolded it" is_real_dir "$HOME/$RU_DIR_REL"
  check "npm ci ran in the real dir" [ -d "$HOME/$RU_DIR_REL/node_modules/playwright" ]
  check "nothing written into the repo" [ "$repo_before" = "$(repo_snapshot)" ]
  teardown

  setup "render-url: still a link into the repo after stowing"
  bazzite
  dotfiles_fixture
  stub stow   # stows nothing, so the fold stays
  mkdir -p "$HOME/.local/share"
  ln -s ../../Projects/Home/dotfiles/render-url/.local/share/render-url "$HOME/.local/share/render-url"
  repo_before="$(repo_snapshot)"
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "warns about the link" has "$OUT" "skipped render-url dependencies: .* resolves into the dotfiles repo"
  check "never runs npm" log_lacks '^mise exec -- (npm ci|npx)'
  check "nothing written into the repo" [ "$repo_before" = "$(repo_snapshot)" ]
  teardown

  setup "render-url: package absent from dotfiles"
  bazzite
  dotfiles_fixture
  rm -rf "$HOME/Projects/Home/dotfiles/render-url"
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "warns the package is missing" has "$OUT" "dotfiles has no 'render-url' package"
  check "no render-url step" lacks "$OUT" "render-url dependencies"
  check "never runs npm ci" log_lacks '^mise exec -- (npm ci|npx)'
  teardown

  setup "render-url: pop run"
  os_release pop "ubuntu debian"
  dotfiles_fixture
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "shellcheck from apt" log_has '^sudo apt-get install -y shellcheck$'
  check "npm ci through mise exec" [ "$(ru_log 'npm ci$')" -eq 1 ]
  check "node_modules installed" [ -d "$HOME/$RU_DIR_REL/node_modules/playwright" ]
  check "PATH npm never used" log_lacks '^npm '
  teardown
}

# Salesforce cases use the same guarded whole-script sandbox as platform tests.
salesforce_setup() {
  setup "Salesforce $1"
  if [ "$1" = debian ]; then os_release pop ubuntu; else bazzite; fi
  dotfiles_fixture
}

test_salesforce_platforms() {
  local platform
  for platform in atomic debian; do
    salesforce_setup "$platform"
    run_linux
    check "Salesforce install succeeded" [ "$RC" -eq 0 ]
    check "both packages via mise" log_has '^mise exec -- npm install -g @salesforce/cli @salesforce/lwc-language-server$'
    check "plugin via mise" log_has '^mise exec -- sf plugins install code-analyzer$'
    check "after Node" logged_before '^mise use -g node@lts$' '^mise exec -- npm install -g @salesforce'
    check "sf shim exists" [ -x "$HOME/.local/share/mise/shims/sf" ]
    : > "$LOG"; run_linux
    check "packages skipped independently" log_lacks '^mise exec -- npm install -g @salesforce'
    check "plugin skipped" log_lacks '^mise exec -- sf plugins install'
    rm "$STATE/@salesforce/lwc-language-server"
    : > "$LOG"; run_linux
    check "only missing LWC installed" log_has '^mise exec -- npm install -g @salesforce/lwc-language-server$'
    check "CLI not upgraded" log_lacks '^mise exec -- npm install -g @salesforce/cli'
    teardown
  done
}

test_salesforce_dry_run() {
  salesforce_setup atomic
  local before; before="$(home_snapshot)"
  run_linux --dry-run
  check "plans npm packages" has "$OUT" 'exec -- npm install -g @salesforce/cli @salesforce/lwc-language-server'
  check "plans plugin" has "$OUT" 'exec -- sf plugins install code-analyzer'
  check "no mise executed" log_lacks '^mise '
  check "HOME unchanged" [ "$before" = "$(home_snapshot)" ]
  teardown
}

test_salesforce_no_node() {
  salesforce_setup atomic
  export STUB_MISE_RC=1
  run_linux
  unset STUB_MISE_RC
  check "Salesforce skip warning" has "$OUT" 'skipped Salesforce tools: no usable mise-managed Node'
  check "no Salesforce commands" log_lacks '^mise exec -- (sf|npm .*@salesforce)'
  teardown
}

salesforce_failure() {
  salesforce_setup atomic
  touch "$STATE/$1"
  run_linux
  check "Salesforce failure is nonfatal" [ "$RC" -eq 0 ]
  check "specific warning" has "$OUT" "$2"
  rm "$STATE/$1"; : > "$LOG"; run_linux
  check "next run retries" log_has "$3"
  teardown
}
test_salesforce_npm_failure() { salesforce_failure sf-npm-fail 'Salesforce npm install failed' '^mise exec -- npm install -g @salesforce'; }
test_salesforce_plugin_failure() { salesforce_failure sf-plugin-fail 'Salesforce code-analyzer install failed' '^mise exec -- sf plugins install code-analyzer$'; }
test_salesforce_listing_failure() { salesforce_failure sf-list-fail 'Salesforce plugin listing failed' '^mise exec -- sf plugins install code-analyzer$'; }

test_salesforce_unusable_node() {
  salesforce_failure sf-node-fail 'skipped Salesforce tools: mise-managed Node is unusable' '^mise exec -- npm install -g @salesforce'
}

test_salesforce_reshim_failure() {
  salesforce_setup atomic
  mise_node_fixture
  export STUB_RESHIM_RC=1
  run_linux
  unset STUB_RESHIM_RC
  check "reshim failure nonfatal" [ "$RC" -eq 0 ]
  check "reshim warning" has "$OUT" 'Salesforce mise reshim failed'
  check "plugin deferred" log_lacks '^mise exec -- sf plugins'
  : > "$LOG"; run_linux
  check "shim repair retried" log_has '^mise reshim$'
  check "plugin installed after repair" log_has '^mise exec -- sf plugins install code-analyzer$'
  teardown
}

# The stow commands a preview prints must be exactly the ones a real run runs,
# per package (folding and --no-folding alike), whether or not the dotfiles
# repo is cloned yet.
test_stow_preview_matches_run() {
  local repo preview_missing preview_cloned ran
  setup "stow preview matches the real run"
  bazzite
  repo="$HOME/Projects/Home/dotfiles"
  run_linux --dry-run
  check "missing-repo dry run exits 0" [ "$RC" -eq 0 ]
  preview_missing="$(sed -n 's/^ *\[dry-run\] \(stow .*\)$/\1/p' <<<"$OUT")"
  dotfiles_fixture
  run_linux --dry-run
  check "cloned-repo dry run exits 0" [ "$RC" -eq 0 ]
  preview_cloned="$(sed -n 's/^ *\[dry-run\] \(stow .*\)$/\1/p' <<<"$OUT")"
  : > "$LOG"
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  ran="$(grep '^stow ' "$LOG")"
  check "run stowed every package" [ "$(grep -c . <<<"$ran")" -eq "${#ALL_PACKAGES[@]}" ]
  check "run folds tmux" has "$ran" "^stow --dir=$repo --target=$HOME --restow tmux$"
  check "run does not fold claude" has "$ran" "^stow --no-folding --dir=$repo --target=$HOME --restow claude$"
  check "missing-repo preview = real run" [ "$preview_missing" = "$ran" ]
  check "cloned-repo preview = real run" [ "$preview_cloned" = "$ran" ]
  teardown
}

# ── Tests: the claude package ────────────────────────────────────────────────

# Claude Code writes sessions, credentials and history under ~/.claude, so the
# package must never fold ~/.claude (or ~/.claude/skills) into the repo.
test_claude_package() {
  local df before repo_before os backups
  for os in bazzite pop; do
    setup "claude: $os fresh HOME (no ~/.claude)"
    if [ "$os" = bazzite ]; then bazzite; else os_release pop "ubuntu debian"; fi
    dotfiles_fixture
    df="$HOME/Projects/Home/dotfiles/claude/.claude"
    before="$(home_snapshot)"
    run_linux --dry-run
    check "dry run exits 0" [ "$RC" -eq 0 ]
    check "plans stowing claude without folding" has "$OUT" '\[dry-run\] stow --no-folding .* --restow claude$'
    check "dry run changes nothing" [ "$before" = "$(home_snapshot)" ]
    check "dry run never mutates" log_lacks "$MUTATING"
    repo_before="$(repo_snapshot)"
    run_linux
    check "run exits 0" [ "$RC" -eq 0 ]
    check ".claude is a real dir" is_real_dir "$HOME/.claude"
    check ".claude/skills is a real dir" is_real_dir "$HOME/.claude/skills"
    check "CLAUDE.md is a link" [ -L "$HOME/.claude/CLAUDE.md" ]
    check "CLAUDE.md resolves into the package" [ "$(realpath "$HOME/.claude/CLAUDE.md")" = "$(realpath "$df/CLAUDE.md")" ]
    check "route-local skill is stowed" [ "$(realpath "$HOME/.claude/skills/route-local/SKILL.md")" = "$(realpath "$df/skills/route-local/SKILL.md")" ]
    echo '{"token":"x"}' > "$HOME/.claude/.credentials.json"
    mkdir -p "$HOME/.claude/skills/new-skill"
    check "Claude Code's writes stay out of the repo" [ "$repo_before" = "$(repo_snapshot)" ]
    teardown
  done

  setup "claude: existing ~/.claude with other content"
  bazzite
  dotfiles_fixture
  mkdir -p "$HOME/.claude/projects/p" "$HOME/.claude/skills/mine"
  echo '{"token":"x"}' > "$HOME/.claude/.credentials.json"
  echo '{"session":1}' > "$HOME/.claude/projects/p/s.jsonl"
  echo "# my skill" > "$HOME/.claude/skills/mine/SKILL.md"
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check ".claude is still a real dir" is_real_dir "$HOME/.claude"
  check ".claude/skills is still a real dir" is_real_dir "$HOME/.claude/skills"
  check "credentials untouched" [ "$(cat "$HOME/.claude/.credentials.json")" = '{"token":"x"}' ]
  check "credentials still a real file" [ ! -L "$HOME/.claude/.credentials.json" ]
  check "sessions untouched" [ "$(cat "$HOME/.claude/projects/p/s.jsonl")" = '{"session":1}' ]
  check "own skill untouched" [ "$(cat "$HOME/.claude/skills/mine/SKILL.md")" = "# my skill" ]
  check "CLAUDE.md is stowed" [ -L "$HOME/.claude/CLAUDE.md" ]
  check "nothing backed up" lacks "$OUT" "backed up ~/.claude"
  teardown

  setup "claude: existing real CLAUDE.md is backed up, never adopted"
  bazzite
  dotfiles_fixture
  mkdir -p "$HOME/.claude"
  echo "# my local CLAUDE.md" > "$HOME/.claude/CLAUDE.md"
  before="$(home_snapshot)"; repo_before="$(repo_snapshot)"
  run_linux --dry-run
  check "dry run plans the backup" has "$OUT" "would back up ~/.claude/CLAUDE.md \("
  check "dry run changes nothing" [ "$before" = "$(home_snapshot)" ]
  check "dry run never mutates" log_lacks "$MUTATING"
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  backups="$(find "$HOME/.local/state/laptop/backups" -path '*/.claude/CLAUDE.md' -type f)"
  check "backed up once" [ "$(grep -c . <<<"$backups")" -eq 1 ]
  check "backup keeps its contents" [ "$(cat "$backups")" = "# my local CLAUDE.md" ]
  check "CLAUDE.md is now the stowed link" [ -L "$HOME/.claude/CLAUDE.md" ]
  check "never adopted into the repo" [ "$repo_before" = "$(repo_snapshot)" ]
  teardown
}

# ── Tests: bin and agy are not folded ────────────────────────────────────────

# Installers drop scripts into ~/bin and agy writes into ~/.config/agy, so
# neither may be a folded link into the repo. A machine stowed before this
# change has both folded: a --restow --no-folding must turn them into real
# directories without backups or conflicts.
test_bin_agy_no_folding() {
  local os repo repo_before before
  for os in bazzite pop; do
    setup "bin/agy: $os fresh HOME"
    if [ "$os" = bazzite ]; then bazzite; else os_release pop "ubuntu debian"; fi
    dotfiles_fixture
    repo="$HOME/Projects/Home/dotfiles"
    before="$(home_snapshot)"
    run_linux --dry-run
    check "dry run plans bin without folding" has "$OUT" "\[dry-run\] stow --no-folding --dir=$repo --target=$HOME --restow bin$"
    check "dry run plans agy without folding" has "$OUT" "\[dry-run\] stow --no-folding --dir=$repo --target=$HOME --restow agy$"
    check "dry run changes nothing" [ "$before" = "$(home_snapshot)" ]
    run_linux
    check "run exits 0" [ "$RC" -eq 0 ]
    check "HOME/bin is a real dir" is_real_dir "$HOME/bin"
    check "HOME/.config/agy is a real dir" is_real_dir "$HOME/.config/agy"
    check "bin script is stowed" [ "$(realpath "$HOME/bin/hello")" = "$(realpath "$repo/bin/bin/hello")" ]
    check "agy config is stowed" [ "$(realpath "$HOME/.config/agy/permissions.json")" = "$(realpath "$repo/agy/.config/agy/permissions.json")" ]
    repo_before="$(repo_snapshot)"
    echo "#!/bin/sh" > "$HOME/bin/installed-by-something"
    echo "{}" > "$HOME/.config/agy/state.json"
    check "new files stay out of the repo" [ "$repo_before" = "$(repo_snapshot)" ]
    teardown
  done

  setup "bin/agy: folded by an earlier stow"
  bazzite
  dotfiles_fixture
  repo="$HOME/Projects/Home/dotfiles"
  mkdir -p "$HOME/.config"
  ln -s Projects/Home/dotfiles/bin/bin "$HOME/bin"
  ln -s ../Projects/Home/dotfiles/agy/.config/agy "$HOME/.config/agy"
  before="$(home_snapshot)"; repo_before="$(repo_snapshot)"
  run_linux --dry-run
  check "dry run exits 0" [ "$RC" -eq 0 ]
  check "dry run plans no backups" lacks "$OUT" "back up"
  check "dry run changes nothing" [ "$before" = "$(home_snapshot)" ]
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "no stow failures" lacks "$OUT" "stow failed|skipped stowing"
  check "nothing backed up" lacks "$OUT" "backed up"
  check "HOME/bin unfolded into a real dir" is_real_dir "$HOME/bin"
  check "HOME/.config/agy unfolded into a real dir" is_real_dir "$HOME/.config/agy"
  check "bin script still stowed" [ "$(realpath "$HOME/bin/hello")" = "$(realpath "$repo/bin/bin/hello")" ]
  check "agy config still stowed" [ "$(realpath "$HOME/.config/agy/permissions.json")" = "$(realpath "$repo/agy/.config/agy/permissions.json")" ]
  check "repo unchanged by the unfold" [ "$repo_before" = "$(repo_snapshot)" ]
  echo "#!/bin/sh" > "$HOME/bin/installed-by-something"
  check "new ~/bin files stay out of the repo" [ "$repo_before" = "$(repo_snapshot)" ]
  run_linux
  check "re-run exits 0" [ "$RC" -eq 0 ]
  check "re-run has no stow failures" lacks "$OUT" "stow failed|skipped stowing"
  check "re-run keeps ~/bin a real dir" is_real_dir "$HOME/bin"
  check "re-run keeps the foreign file" [ -f "$HOME/bin/installed-by-something" ] && [ ! -L "$HOME/bin/installed-by-something" ]
  teardown
}

# ── Tests: agent CLIs and ~/.local/bin links ─────────────────────────────────

# Links a fresh run must leave: claude/codex/pi straight into Node LTS's bin
# dir (Omnigent's renamed argv[0] breaks mise shims), Node's own tools to shims.
agent_links_ok() {
  local data="$HOME/.local/share/mise" t
  for t in "${AGENT_TOOLS[@]}"; do
    [ "$(readlink "$HOME/.local/bin/$t")" = "$data/installs/node/lts/bin/$t" ] && [ -x "$HOME/.local/bin/$t" ] || return 1
  done
  for t in "${NODE_TOOLS[@]}"; do
    [ "$(readlink "$HOME/.local/bin/$t")" = "$data/shims/$t" ] && [ -x "$HOME/.local/bin/$t" ] || return 1
  done
}

test_agent_clis() {
  local os before data pkg links_before backup
  for os in bazzite pop; do
    setup "agent CLIs: $os fresh"
    if [ "$os" = bazzite ]; then bazzite; else os_release pop "ubuntu debian"; fi
    dotfiles_fixture
    data="$HOME/.local/share/mise"
    before="$(home_snapshot)"
    run_linux --dry-run
    check "dry run exits 0" [ "$RC" -eq 0 ]
    for pkg in @anthropic-ai/claude-code @openai/codex @earendil-works/pi-coding-agent; do
      check "dry run plans $pkg through mise's npm" has "$OUT" "\[dry-run\] $data/shims/npm install -g $pkg$"
    done
    check "dry run plans corepack enable pnpm" has "$OUT" "\[dry-run\] .*mise exec -- corepack enable pnpm$"
    check "dry run plans claude's link into Node LTS" has "$OUT" "\[dry-run\] ln -sfn $data/installs/node/lts/bin/claude $HOME/.local/bin/claude$"
    check "dry run plans node's link to its shim" has "$OUT" "\[dry-run\] ln -sfn $data/shims/node $HOME/.local/bin/node$"
    check "dry run plans 8 links" [ "$(grep -c '\[dry-run\] ln -sfn' <<<"$OUT")" -eq 8 ]
    check "dry run changes nothing" [ "$before" = "$(home_snapshot)" ]
    check "dry run never mutates" log_lacks "$MUTATING"
    run_linux
    check "run exits 0" [ "$RC" -eq 0 ]
    for pkg in @anthropic-ai/claude-code @openai/codex @earendil-works/pi-coding-agent; do
      check "installs $pkg through mise's npm shim, after node" logged_before '^mise (use -g node@lts|install node)$' "^mise-shim-npm install -g $pkg$"
    done
    check "pnpm enabled with Node's own corepack" log_has '^mise-22.12.0-corepack enable pnpm$'
    check "pnpm landed in Node's bin dir" [ -x "$data/installs/node/22.12.0/bin/pnpm" ]
    check "reshim after the installs" logged_before '^mise-22.12.0-corepack enable pnpm$' '^mise reshim$'
    check "pnpm has a shim" [ -x "$data/shims/pnpm" ]
    check "every ~/.local/bin link is right" agent_links_ok
    check "no agent CLI warnings" lacks "$OUT" "! .*(agent CLIs|not linking|pnpm|corepack)"
    check "PATH npm never used" log_lacks '^npm '
    links_before="$(ls -l "$HOME/.local/bin")"
    : > "$LOG"
    run_linux
    check "re-run exits 0" [ "$RC" -eq 0 ]
    check "re-run installs nothing with npm" log_lacks 'npm install'
    check "re-run does not run corepack" log_lacks 'corepack'
    check "re-run does not reshim" log_lacks '^mise reshim'
    check "re-run reports the links" has "$OUT" "already linked: ~/.local/bin/claude -> $data/installs/node/lts/bin/claude"
    check "re-run leaves the links alone" [ "$links_before" = "$(ls -l "$HOME/.local/bin")" ]
    teardown
  done

  setup "agent CLIs: existing ~/.local/bin entries"
  bazzite
  dotfiles_fixture
  data="$HOME/.local/share/mise"
  mkdir -p "$HOME/.local/bin"
  echo "my own claude" > "$HOME/.local/bin/claude"
  ln -s /nonexistent/codex "$HOME/.local/bin/codex"                       # dangling
  ln -s "$HOME/.local/share/claude/versions/1.0" "$HOME/.local/bin/pi"    # some other link
  ln -s "$data/shims/node" "$HOME/.local/bin/node"                         # already right
  before="$(home_snapshot)"
  run_linux --dry-run
  check "dry run plans the claude backup" has "$OUT" "would back up ~/.local/bin/claude \("
  check "dry run backs up nothing else" [ "$(grep -c 'would back up ~/.local/bin/' <<<"$OUT")" -eq 1 ]
  check "dry run changes nothing" [ "$before" = "$(home_snapshot)" ]
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  backup="$(find "$HOME/.local/state/laptop/backups" -path '*/.local/bin/claude' -type f)"
  check "regular claude backed up once" [ "$(grep -c . <<<"$backup")" -eq 1 ]
  check "backup keeps its contents" [ "$(cat "$backup")" = "my own claude" ]
  check "every ~/.local/bin link is right" agent_links_ok
  check "only the regular file was backed up" [ "$(find "$HOME/.local/state/laptop/backups" -path '*/.local/bin/*' | wc -l)" -eq 1 ]
  teardown

  setup "agent CLIs: one npm install fails"
  bazzite
  dotfiles_fixture
  data="$HOME/.local/share/mise"
  STUB_AGENT_FAIL=@openai/codex run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "warns about codex" has "$OUT" "'npm install -g @openai/codex' failed; next run will retry"
  check "still installs pi after the failure" log_has '^mise-shim-npm install -g @earendil-works/pi-coding-agent$'
  check "warns codex is not linked" has "$OUT" "not linking ~/.local/bin/codex: $data/installs/node/lts/bin/codex is missing"
  check "no codex link" [ ! -e "$HOME/.local/bin/codex" ] && [ ! -L "$HOME/.local/bin/codex" ]
  check "claude still linked" [ "$(readlink "$HOME/.local/bin/claude")" = "$data/installs/node/lts/bin/claude" ]
  : > "$LOG"
  run_linux
  check "re-run retries only codex" [ "$(log_count '^mise-shim-npm install -g')" -eq 1 ] && log_has '^mise-shim-npm install -g @openai/codex$'
  check "re-run links everything" agent_links_ok
  teardown

  setup "agent CLIs: corepack fails"
  bazzite
  dotfiles_fixture
  STUB_COREPACK_RC=1 run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "warns about corepack" has "$OUT" "'corepack enable pnpm' failed; next run will retry"
  check "no pnpm link" [ ! -L "$HOME/.local/bin/pnpm" ]
  check "agent CLIs still linked" [ -x "$HOME/.local/bin/claude" ] && [ -x "$HOME/.local/bin/pi" ]
  teardown

  setup "agent CLIs: Node LTS without corepack"
  bazzite
  dotfiles_fixture
  mise_node_fixture
  rm "$HOME/.local/share/mise/installs/node/22.12.0/bin/corepack"
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "warns pnpm is skipped" has "$OUT" "skipped pnpm: Node LTS has no corepack"
  check "corepack never run" log_lacks 'corepack enable'
  check "warns corepack is not linked" has "$OUT" "not linking ~/.local/bin/corepack"
  check "no corepack/pnpm links" [ ! -L "$HOME/.local/bin/corepack" ] && [ ! -L "$HOME/.local/bin/pnpm" ]
  teardown

  setup "agent CLIs: ~/.local/bin folded into the repo"
  bazzite
  dotfiles_fixture
  mkdir -p "$HOME/.local"
  ln -s ../Projects/Home/dotfiles/applications/.local/bin "$HOME/.local/bin"
  local repo_before; repo_before="$(repo_snapshot)"
  run_linux
  check "run exits 0" [ "$RC" -eq 0 ]
  check "warns and skips the links" has "$OUT" "skipped ~/.local/bin links: $HOME/.local/bin resolves into the dotfiles repo"
  check "nothing linked into the repo" [ "$repo_before" = "$(repo_snapshot)" ]
  teardown
}

# ── Tests: package lists match the dotfiles repo ─────────────────────────────

# Top-level package directories of adamdaw/dotfiles (main), without docs/,
# tests/ and dot-dirs. Update with the dotfiles repo. Set
# LAPTOP_TEST_DOTFILES_DIR to a checkout to check this list against it too
# (read-only; skipped otherwise, so the tests need no network or checkout).
DOTFILES_PACKAGES=(agy applications bash bat bin claude ghostty git nvim render-url ripgrep ssh starship tmux xdg zsh)
# In dotfiles but not in STOW_PACKAGES, on purpose: xdg makes Ghostty the
# default terminal, so it is stowed only on Bazzite GNOME with Ghostty present
# (prepare_default_terminal adds it; see test_default_terminal).
CONDITIONAL_PACKAGES=(xdg)

script_list() { sed -n "s/^$1=(\(.*\))\$/\1/p" "$SCRIPT"; }
sorted() { printf '%s\n' "$@" | sort | tr '\n' ' '; }

test_stow_packages_match_dotfiles() {
  setup "STOW_PACKAGES matches the dotfiles packages"
  local -a stow nofold dirs=()
  read -ra stow <<<"$(script_list STOW_PACKAGES)"
  read -ra nofold <<<"$(script_list NO_FOLD_PACKAGES)"
  local p
  check "parsed STOW_PACKAGES" [ "${#stow[@]}" -gt 0 ]
  check "STOW_PACKAGES + conditional = dotfiles packages" [ "$(sorted "${stow[@]}" "${CONDITIONAL_PACKAGES[@]}")" = "$(sorted "${DOTFILES_PACKAGES[@]}")" ]
  for p in "${CONDITIONAL_PACKAGES[@]}"; do
    check "$p is not stowed unconditionally" lacks " ${stow[*]} " " $p "
  done
  for p in "${nofold[@]}"; do
    check "--no-folding package $p is a dotfiles package" has " ${DOTFILES_PACKAGES[*]} " " $p "
  done
  check "tests' ALL_PACKAGES = STOW_PACKAGES" [ "$(sorted "${ALL_PACKAGES[@]}")" = "$(sorted "${stow[@]}")" ]
  check "tests' NO_FOLD_PACKAGES = NO_FOLD_PACKAGES minus conditional" [ "$(sorted "${NO_FOLD_PACKAGES[@]}" "${CONDITIONAL_PACKAGES[@]}")" = "$(sorted "${nofold[@]}")" ]
  if [ -n "${LAPTOP_TEST_DOTFILES_DIR:-}" ]; then
    for p in "$LAPTOP_TEST_DOTFILES_DIR"/*/; do
      p="${p%/}"; p="${p##*/}"
      case "$p" in docs|tests) ;; *) dirs+=("$p") ;; esac
    done
    check "DOTFILES_PACKAGES = $LAPTOP_TEST_DOTFILES_DIR's top-level dirs" [ "$(sorted "${dirs[@]}")" = "$(sorted "${DOTFILES_PACKAGES[@]}")" ]
  else
    printf "  skip LAPTOP_TEST_DOTFILES_DIR unset: DOTFILES_PACKAGES not checked against a checkout\n"
  fi
  teardown
}

# ── Run ──────────────────────────────────────────────────────────────────────

TESTS=(
  test_salesforce_unusable_node
  test_salesforce_reshim_failure
  test_salesforce_platforms
  test_salesforce_dry_run
  test_salesforce_no_node
  test_salesforce_npm_failure
  test_salesforce_plugin_failure
  test_salesforce_listing_failure
  test_default_terminal
  test_default_terminal_skips
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
  test_node_readiness
  test_mise_config_parsing
  test_mise_apt_failures
  test_hand_made_repo_links
  test_gitconfig_carry_over
  test_gitconfig_local_kept
  test_gitconfig_missing_identity
  test_gitconfig_dry_run
  test_gitconfig_unreadable
  test_gitconfig_includes_refused
  test_gitconfig_write_failure_retry
  test_gitconfig_local_not_regular
  test_gitconfig_identity_final
  test_gitconfig_bare_key
  test_global_config_not_written_into_repo
  test_git_stub_sandbox
  test_gitconfig_local_includes_refused
  test_gitconfig_listing_failure
  test_gitconfig_rename_race
  test_gitconfig_interrupted
  test_gitconfig_xdg_identity
  test_git_stub_includes
  test_font_detection
  test_render_url
  test_claude_package
  test_stow_preview_matches_run
  test_bin_agy_no_folding
  test_agent_clis
  test_stow_packages_match_dotfiles
)

for t in "${TESTS[@]}"; do
  printf "%s\n" "$t"
  "$t"
done

printf "\n%d test functions, %d assertions: %d passed, %d failed\n" "${#TESTS[@]}" "$((PASS + FAIL))" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
