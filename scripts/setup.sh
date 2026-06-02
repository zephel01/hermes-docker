#!/usr/bin/env bash
# scripts/setup.sh — interactive first-time setup for hermes-docker.
#
# Automates docs/setup.md §3-1 through §3-3 plus a shell alias install:
#
#   1. Check prerequisites (docker, docker compose v2, git, openssl)
#   2. Run ./scripts/bootstrap.sh (submodule init + local patches)
#   3. Ensure ~/.hermes/ and ~/workspace/ exist
#   4. Generate ./.env (HOST_UID, HOST_GID, SEARXNG_SECRET_KEY)
#   5. Scaffold ~/.hermes/.env if missing (mode 0600)
#   6. Warn if ./hermes-webui/.env still has the default password placeholder
#   7. Install the `hermes-docker` alias into ~/.zshrc and/or ~/.bashrc
#
# Idempotent: safe to re-run. Pass -y / --yes to assume "yes" for prompts.

set -euo pipefail

# ── colors / output helpers ────────────────────────────────────────────────
if [ -t 1 ]; then
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
else
    C_GREEN= C_YELLOW= C_RED= C_BOLD= C_DIM= C_RESET=
fi
step() { printf '\n%s==>%s %s%s%s\n' "$C_BOLD$C_GREEN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
ok()   { printf '  %s✓%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf '  %s✗%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
info() { printf '    %s%s%s\n'  "$C_DIM"   "$*"      "$C_RESET"; }

ASSUME_YES=
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help)
            sed -n '2,/^# Idempotent/p' "$0" | sed -E 's/^# ?//'
            exit 0 ;;
        *) fail "unknown arg: $arg"; exit 1 ;;
    esac
done

ask_yn() {
    # usage: ask_yn "prompt" [default y|n]
    local prompt="$1" default="${2:-n}" hint="[y/N]" reply
    [ "$default" = "y" ] && hint="[Y/n]"
    if [ -n "$ASSUME_YES" ]; then
        echo "$prompt $hint y (assumed via -y)"
        return 0
    fi
    if [ ! -t 0 ]; then
        # non-interactive shell — fall back to default
        echo "$prompt $hint $default (non-interactive)"
        [ "$default" = "y" ]
        return $?
    fi
    read -r -p "$prompt $hint " reply || true
    reply="${reply:-$default}"
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *)           return 1 ;;
    esac
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

# ── sanity ─────────────────────────────────────────────────────────────────
[ -f docker-compose.yml ] || { fail "not in hermes-docker repo root: $repo_root"; exit 1; }
[ -x scripts/bootstrap.sh ] || { fail "scripts/bootstrap.sh missing or not executable"; exit 1; }

echo "${C_BOLD}hermes-docker setup${C_RESET}  ${C_DIM}@ $repo_root${C_RESET}"

# ── 1. prerequisites ───────────────────────────────────────────────────────
step "1. prerequisites"
missing=0
for cmd in docker git openssl; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd: $(command -v "$cmd")"
    else
        fail "$cmd not found in PATH"
        missing=1
    fi
done
if docker compose version >/dev/null 2>&1; then
    ok "docker compose v2: $(docker compose version --short 2>/dev/null || echo present)"
else
    fail "docker compose v2 plugin not available"
    missing=1
fi
[ "$missing" -eq 0 ] || { fail "fix the above and re-run"; exit 1; }

# ── 2. bootstrap (submodules + patches) ────────────────────────────────────
step "2. submodule + patches"
./scripts/bootstrap.sh

# ── 3. host directories ────────────────────────────────────────────────────
step "3. host directories"
for d in "$HOME/.hermes" "$HOME/workspace"; do
    if [ -d "$d" ]; then
        ok "exists: $d"
    else
        if ask_yn "  create $d ?" y; then
            mkdir -p "$d"
            ok "created: $d"
        else
            warn "skipped — will be auto-created on compose up but may be root-owned"
        fi
    fi
done

# ── 4. ./.env (compose vars) ───────────────────────────────────────────────
step "4. ./.env (compose variable substitution)"
host_uid="$(id -u)"
host_gid="$(id -g)"

if [ -f .env ]; then
    # Preserve existing HOST_UID / HOST_GID / SEARXNG_SECRET_KEY — they are
    # tied to the running containers and the seeded named volume; changing
    # them on an existing setup risks permission breakage in the
    # /opt/hermes named volume after container recreation.
    cur_uid="$(awk -F= '/^HOST_UID=/{print $2; exit}' .env || true)"
    cur_gid="$(awk -F= '/^HOST_GID=/{print $2; exit}' .env || true)"

    tmp_env="$(mktemp)"
    cp .env "$tmp_env"

    if [ -z "$cur_uid" ]; then
        echo "HOST_UID=$host_uid" >> "$tmp_env"
        info "added HOST_UID=$host_uid (was missing)"
    elif [ "$cur_uid" != "$host_uid" ]; then
        warn "HOST_UID in .env is $cur_uid but \`id -u\` says $host_uid"
        info "leaving .env unchanged. If you need to switch, also recreate the"
        info "named volume: \`docker compose down && docker volume rm hermes-docker_hermes-agent-src\`"
    fi
    if [ -z "$cur_gid" ]; then
        echo "HOST_GID=$host_gid" >> "$tmp_env"
        info "added HOST_GID=$host_gid (was missing)"
    elif [ "$cur_gid" != "$host_gid" ]; then
        warn "HOST_GID in .env is $cur_gid but \`id -g\` says $host_gid"
    fi
    if ! grep -q '^SEARXNG_SECRET_KEY=' .env; then
        echo "SEARXNG_SECRET_KEY=$(openssl rand -hex 32)" >> "$tmp_env"
        info "added SEARXNG_SECRET_KEY (was missing)"
    fi
    mv "$tmp_env" .env
    ok ".env: HOST_UID=${cur_uid:-$host_uid} HOST_GID=${cur_gid:-$host_gid} (existing values preserved)"
else
    cat > .env <<EOF
# Generated by scripts/setup.sh — compose variable substitution only.
# (Add your provider API keys to ~/.hermes/.env, not here.)
SEARXNG_SECRET_KEY=$(openssl rand -hex 32)
HOST_UID=$host_uid
HOST_GID=$host_gid
EOF
    ok "created .env (HOST_UID=$host_uid HOST_GID=$host_gid + fresh SEARXNG_SECRET_KEY)"
fi

# ── 5. ~/.hermes/.env (provider secrets) ───────────────────────────────────
step "5. ~/.hermes/.env (provider secrets — single source of truth)"
hermes_env="$HOME/.hermes/.env"
if [ -f "$hermes_env" ]; then
    ok "$hermes_env exists — leaving its contents untouched"
    info "edit it yourself to add ANTHROPIC_API_KEY / OPENROUTER_API_KEY / etc."
    # tighten perms if too open (don't break group bits if user set them on purpose)
    cur_mode="$(stat -f '%Lp' "$hermes_env" 2>/dev/null || stat -c '%a' "$hermes_env" 2>/dev/null || echo "")"
    case "$cur_mode" in
        600|640|644) : ;;
        *) warn "permissions on $hermes_env are $cur_mode — consider: chmod 0600 $hermes_env" ;;
    esac
else
    cat > "$hermes_env" <<'EOF'
# Hermes Agent secrets — read by BOTH the gateway agent (hermes-agent
# container) and the webui's in-process agent (hermes-webui container).
# This is the single source of truth for provider API keys.
#
# Uncomment / fill in the providers you actually use:
#
# ANTHROPIC_API_KEY=sk-ant-...
# OPENAI_API_KEY=sk-...
# OPENROUTER_API_KEY=...
# GEMINI_API_KEY=...
# XAI_API_KEY=...
#
# Web tool secrets (only needed if config.yaml uses them):
# FIRECRAWL_API_KEY=fc-...        # web.extract_backend: firecrawl
# EXA_API_KEY=...                 # web.extract_backend: exa
# TAVILY_API_KEY=...
# BROWSERBASE_API_KEY=...
EOF
    chmod 0600 "$hermes_env"
    ok "created scaffold: $hermes_env  (mode 0600)"
    warn "remember to add your provider API keys before 'docker compose up'"
fi

# ── 6. webui password sanity ───────────────────────────────────────────────
step "6. ./hermes-webui/.env password check"
webui_env="hermes-webui/.env"
if [ -f "$webui_env" ]; then
    if grep -q '^HERMES_WEBUI_PASSWORD=CHANGE_ME_STRONG_PASSWORD' "$webui_env"; then
        warn "HERMES_WEBUI_PASSWORD is still the default placeholder"
        info "edit $webui_env and set a strong password before exposing the WebUI"
    elif grep -q '^HERMES_WEBUI_PASSWORD=' "$webui_env"; then
        ok "$webui_env has a non-default HERMES_WEBUI_PASSWORD"
    else
        warn "no HERMES_WEBUI_PASSWORD line in $webui_env"
    fi
else
    fail "$webui_env not found — submodule may be missing. re-run bootstrap.sh?"
fi

# ── 7. shell alias ─────────────────────────────────────────────────────────
step "7. hermes-docker shell alias"

alias_line="alias hermes-docker='docker exec -it -u hermes hermes-agent /opt/hermes/.venv/bin/hermes'"
marker_start="# >>> hermes-docker alias (managed by scripts/setup.sh) >>>"
marker_end="# <<< hermes-docker alias <<<"

install_alias_into() {
    local rc="$1"
    if [ ! -f "$rc" ]; then
        if ask_yn "  $rc does not exist — create it?" n; then
            touch "$rc"
        else
            info "skipped: $rc"
            return 0
        fi
    fi
    if grep -qF "$marker_start" "$rc"; then
        ok "$rc already has the alias block (managed)"
        return 0
    fi
    if grep -qF "alias hermes-docker=" "$rc"; then
        warn "$rc already has a hermes-docker alias (unmanaged) — leaving it alone"
        info "remove the existing line and re-run if you want the managed block"
        return 0
    fi
    {
        printf '\n%s\n' "$marker_start"
        printf '%s\n'   "$alias_line"
        printf '%s\n'   "$marker_end"
    } >> "$rc"
    ok "appended alias block to $rc"
}

case "${SHELL:-}" in
    */zsh)  primary_rc="$HOME/.zshrc"  ; secondary_rc="$HOME/.bashrc" ;;
    */bash) primary_rc="$HOME/.bashrc" ; secondary_rc="$HOME/.zshrc"  ;;
    *)      primary_rc="$HOME/.bashrc" ; secondary_rc="$HOME/.zshrc"  ;;
esac

install_alias_into "$primary_rc"
if [ -f "$secondary_rc" ] && [ "$secondary_rc" != "$primary_rc" ]; then
    if ask_yn "  also install into $secondary_rc?" n; then
        install_alias_into "$secondary_rc"
    fi
fi

# ── done ───────────────────────────────────────────────────────────────────
step "Done"
cat <<EOF

  ${C_BOLD}Next steps${C_RESET}

    ${C_BOLD}1.${C_RESET} Reload your shell so the alias takes effect:
         ${C_DIM}source $primary_rc${C_RESET}

    ${C_BOLD}2.${C_RESET} Add provider API keys to ${C_BOLD}~/.hermes/.env${C_RESET} if you haven't:
         ${C_DIM}\$EDITOR ~/.hermes/.env${C_RESET}

    ${C_BOLD}3.${C_RESET} Build images and start the stack:
         ${C_DIM}docker compose pull && docker compose build && docker compose up -d${C_RESET}

    ${C_BOLD}4.${C_RESET} Open the UIs:
         WebUI  ${C_DIM}http://127.0.0.1:8787${C_RESET}
         HUD    ${C_DIM}http://127.0.0.1:3001${C_RESET}

  Health checks, in-container ${C_BOLD}hermes${C_RESET} CLI bootstrap (OAuth, model picker,
  gateway setup) → ${C_BOLD}docs/setup.md${C_RESET} §4–§5.

EOF
