#!/usr/bin/env bash
set -Eeuo pipefail

readonly PRIVATE_REPOSITORY='mejechka/pokerops-bootstrap'
readonly GITHUB_OWNER='mejechka'
readonly WRAPPER_COMMIT='d6774a908551b9b0a676f2cf00dcdff7255d5c65'
readonly WRAPPER_SHA256='1de2af5254414825ea71798c404a326faca70696766e6191e4af2686d63e0154'
readonly PLANNER_PGSERVICE='pokerops-planner-migration'

[[ $# -eq 0 ]] || { printf 'usage: deploy.sh\n' >&2; exit 2; }
[[ "$(id -u)" == '0' ]] || { printf 'run through sudo bash\n' >&2; exit 1; }
command -v gh >/dev/null || { printf 'gh is required\n' >&2; exit 1; }
command -v sha256sum >/dev/null || { printf 'sha256sum is required\n' >&2; exit 1; }
[[ "$WRAPPER_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { printf 'wrapper commit must be immutable\n' >&2; exit 1; }

gh auth status --hostname github.com >/dev/null 2>&1 \
  || { printf 'root GitHub CLI authentication is required\n' >&2; exit 1; }
[[ "$(gh api user --jq '.login' 2>/dev/null)" == "$GITHUB_OWNER" ]] \
  || { printf 'root GitHub CLI must be authenticated as mejechka\n' >&2; exit 1; }
[[ "$(gh api "repos/${PRIVATE_REPOSITORY}" --jq '.private and (.permissions.pull == true)' 2>/dev/null)" == 'true' ]] \
  || { printf 'private bootstrap repository access is required\n' >&2; exit 1; }

umask 077
temporary_root="$(mktemp -d /tmp/pokerops-public-entrypoint.XXXXXX)"
trap 'rm -rf -- "$temporary_root"' EXIT INT TERM
private_wrapper="$temporary_root/deploy.sh"

gh api \
  -H 'Accept: application/vnd.github.raw+json' \
  "repos/${PRIVATE_REPOSITORY}/contents/deploy.sh?ref=${WRAPPER_COMMIT}" \
  >"$private_wrapper"
printf '%s  %s\n' "$WRAPPER_SHA256" "$private_wrapper" | sha256sum -c - >/dev/null
chmod 0700 "$private_wrapper"

POKEROPS_PLANNER_PHASE_A_APPROVED=YES \
POKEROPS_PLANNER_PGSERVICE="$PLANNER_PGSERVICE" \
  bash "$private_wrapper"

