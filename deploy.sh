#!/usr/bin/env bash
set -Eeuo pipefail

readonly PRIVATE_REPOSITORY='mejechka/pokerops-bootstrap'
readonly GITHUB_OWNER='mejechka'
readonly PROJECT_REF='xpajqdsppawnjmvewkep'
readonly WRAPPER_COMMIT='d6774a908551b9b0a676f2cf00dcdff7255d5c65'
readonly WRAPPER_SHA256='1de2af5254414825ea71798c404a326faca70696766e6191e4af2686d63e0154'
readonly PLANNER_PGSERVICE='pokerops-planner-migration'
readonly RUNTIME_ENV='/opt/pokerops-tournament-ingestion/shared/.env.tournament.local'
temporary_root=''

die() { printf '%s\n' "$*" >&2; exit 1; }

env_value() {
  local file="$1" key="$2"
  awk -v wanted="$key" '
    index($0, "=") > 0 {
      current = substr($0, 1, index($0, "=") - 1)
      if (current == wanted) {
        value = substr($0, index($0, "=") + 1)
        sub(/\r$/, "", value)
        print value
      }
    }
  ' "$file"
}

validate_runtime_env() {
  [[ -f "$RUNTIME_ENV" && ! -L "$RUNTIME_ENV" ]] \
    || die 'sealed runtime env is missing or is a symlink'
  [[ "$(stat -c '%U:%G:%a' "$RUNTIME_ENV")" == 'root:root:600' ]] \
    || die 'sealed runtime env must be root:root mode 0600'
  [[ "$(grep -cE '^DATABASE_URL=' "$RUNTIME_ENV")" == '1' ]] \
    || die 'sealed runtime env must contain exactly one DATABASE_URL'
}

validate_migration_service() {
  local role database
  role="$(psql "service=${PLANNER_PGSERVICE}" -X -A -t -v ON_ERROR_STOP=1 -c 'select current_user')" \
    || die 'migration service role query failed'
  database="$(psql "service=${PLANNER_PGSERVICE}" -X -A -t -v ON_ERROR_STOP=1 -c 'select current_database()')" \
    || die 'migration service database query failed'
  [[ "$role" != pokerops_tournament_worker* ]] || die 'migration service must not use the worker role'
  [[ "$database" == 'postgres' ]] || die 'migration service must target database postgres'
}

provision_maintenance_role() {
  local password="$1"
  [[ "$password" =~ ^[0-9a-f]{64}$ ]] || die 'generated maintenance password is invalid'
  {
    printf '%s\n' \
      'begin;' \
      "select pg_advisory_xact_lock(hashtextextended('pokerops_planner_role_bootstrap', 0));" \
      'do $maintenance_role$' \
      'begin' \
      "  if not exists (select 1 from pg_roles where rolname = 'pokerops_tournament_maintenance') then" \
      '    create role pokerops_tournament_maintenance login nosuperuser nocreatedb nocreaterole' \
      '      noreplication nobypassrls inherit connection limit 1;' \
      '  end if;' \
      'end' \
      '$maintenance_role$;'
    printf "alter role pokerops_tournament_maintenance login nosuperuser nocreatedb nocreaterole noreplication nobypassrls inherit connection limit 1 password '%s';\n" "$password"
    printf '%s\n' \
      "alter role pokerops_tournament_maintenance set statement_timeout = '60s';" \
      "alter role pokerops_tournament_maintenance set lock_timeout = '5s';" \
      "alter role pokerops_tournament_maintenance set idle_in_transaction_session_timeout = '30s';" \
      'alter role pokerops_tournament_maintenance set search_path = public, pg_catalog;' \
      'commit;'
  } | psql "service=${PLANNER_PGSERVICE}" -X -v ON_ERROR_STOP=1 >/dev/null \
    || die 'maintenance role bootstrap failed'
}

seal_planner_runtime() {
  local maintenance_url="$1"
  [[ "$maintenance_url" == "postgresql://pokerops_tournament_maintenance.${PROJECT_REF}:"* ]] \
    || die 'maintenance URL role is invalid'
  [[ "$maintenance_url" =~ ([?&])sslmode=require([&]|$) ]] \
    || die 'maintenance URL must require TLS'
  sed -i -E \
    '/^(TOURNAMENT_INGESTION_PROFILE|PLANNER_MODE|INFO_FETCH_MODE|ENABLE_SCHEDULER|ENABLE_JOB_WORKER|CATALOG_INTERVAL_MS|TOURNAMENT_MAINTENANCE_DATABASE_URL)=/d' \
    "$RUNTIME_ENV"
  printf '%s\n' \
    'TOURNAMENT_INGESTION_PROFILE=planner' \
    'PLANNER_MODE=maintenance' \
    'INFO_FETCH_MODE=selected_only' \
    'ENABLE_SCHEDULER=false' \
    'ENABLE_JOB_WORKER=false' \
    'CATALOG_INTERVAL_MS=600000' \
    "TOURNAMENT_MAINTENANCE_DATABASE_URL=${maintenance_url}" \
    >>"$RUNTIME_ENV"
  chown root:root "$RUNTIME_ENV"
  chmod 0600 "$RUNTIME_ENV"
}

main() {
  local phase_a_wrapper worker_url worker_suffix maintenance_password maintenance_url
  [[ $# -eq 0 ]] || { printf 'usage: deploy.sh\n' >&2; exit 2; }
  [[ "$(id -u)" == '0' ]] || die 'run through sudo bash'
  for required in gh sha256sum awk grep stat sed dd psql; do
    command -v "$required" >/dev/null || die "${required} is required"
  done
  [[ "$WRAPPER_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die 'wrapper commit must be immutable'

  gh auth status --hostname github.com >/dev/null 2>&1 \
    || die 'root GitHub CLI authentication is required'
  [[ "$(gh api user --jq '.login' 2>/dev/null)" == "$GITHUB_OWNER" ]] \
    || die 'root GitHub CLI must be authenticated as mejechka'
  [[ "$(gh api "repos/${PRIVATE_REPOSITORY}" --jq '.private and (.permissions.pull == true)' 2>/dev/null)" == 'true' ]] \
    || die 'private bootstrap repository access is required'

  umask 077
  temporary_root="$(mktemp -d /tmp/pokerops-public-entrypoint.XXXXXX)"
  trap '[[ -z "$temporary_root" ]] || rm -rf -- "$temporary_root"' EXIT INT TERM
  phase_a_wrapper="$temporary_root/deploy.sh"
  gh api \
    -H 'Accept: application/vnd.github.raw+json' \
    "repos/${PRIVATE_REPOSITORY}/contents/deploy.sh?ref=${WRAPPER_COMMIT}" \
    >"$phase_a_wrapper"
  printf '%s  %s\n' "$WRAPPER_SHA256" "$phase_a_wrapper" | sha256sum -c - >/dev/null
  chmod 0700 "$phase_a_wrapper"

  validate_runtime_env
  validate_migration_service
  worker_url="$(env_value "$RUNTIME_ENV" DATABASE_URL)"
  [[ "$worker_url" == "postgresql://pokerops_tournament_worker.${PROJECT_REF}:"* ]] \
    || die 'worker DATABASE_URL is not for the expected restricted role'
  [[ "$worker_url" == *@* ]] || die 'worker DATABASE_URL is malformed'
  [[ "$worker_url" =~ ([?&])sslmode=require([&]|$) ]] || die 'worker DATABASE_URL must require TLS'
  worker_suffix="${worker_url#*@}"
  maintenance_password="$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | sha256sum | awk '{print $1}')"
  provision_maintenance_role "$maintenance_password"
  maintenance_url="postgresql://pokerops_tournament_maintenance.${PROJECT_REF}:${maintenance_password}@${worker_suffix}"
  seal_planner_runtime "$maintenance_url"
  unset maintenance_password maintenance_url worker_url worker_suffix

  POKEROPS_PLANNER_PHASE_A_APPROVED=YES \
  POKEROPS_PLANNER_PGSERVICE="$PLANNER_PGSERVICE" \
    bash "$phase_a_wrapper"
}

if [[ "${POKEROPS_ENTRYPOINT_LIBRARY_ONLY:-0}" != '1' ]]; then
  main "$@"
fi
