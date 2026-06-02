#!/usr/bin/env bash
#
# bootstrap.sh — initialize submodules + apply local patches.
#
# Idempotent: safe to re-run. Run after `git clone` or `git pull` (especially
# after a submodule bump). Required before `docker compose build`.
#
# What it does:
#   1. `git submodule update --init --recursive` to fetch hermes-webui /
#      hermes-hudui at the pinned revisions.
#   2. Apply every *.patch under patches/<submodule>/ to the matching
#      submodule, skipping ones already applied.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

echo "== bootstrap @ $repo_root =="

# ── Step 1: submodules ────────────────────────────────────────────────────
echo
echo "[1/2] git submodule update --init --recursive"
if [ ! -f .gitmodules ]; then
    echo "  (no .gitmodules — nothing to fetch)"
else
    git submodule update --init --recursive
fi

# ── Step 2: local patches ─────────────────────────────────────────────────
echo
echo "[2/2] apply local patches"

apply_patch() {
    local submodule="$1"
    local patch_file="$2"

    if [ ! -d "$submodule/.git" ] && [ ! -f "$submodule/.git" ]; then
        echo "  [skip] $submodule is not a git checkout — run submodule update first"
        return 0
    fi

    if git -C "$submodule" apply --check --reverse "$patch_file" 2>/dev/null; then
        echo "  [skip] already applied: $patch_file"
        return 0
    fi

    if git -C "$submodule" apply --check "$patch_file" 2>/dev/null; then
        git -C "$submodule" apply "$patch_file"
        echo "  [ok]   applied:        $patch_file"
        return 0
    fi

    echo "  [FAIL] cannot apply (conflict or upstream drift): $patch_file" >&2
    echo "         the upstream file may have moved. Inspect with:" >&2
    echo "           cd $submodule && git apply --check $patch_file" >&2
    return 1
}

if [ -d patches ]; then
    while IFS= read -r -d '' patch_file; do
        submodule="${patch_file#patches/}"
        submodule="${submodule%%/*}"
        apply_patch "$submodule" "$repo_root/$patch_file"
    done < <(find patches -type f -name '*.patch' -print0 | sort -z)
fi

echo
echo "== bootstrap complete =="
echo "Next: docker compose build && docker compose up -d"
