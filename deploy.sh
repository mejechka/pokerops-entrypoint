#!/usr/bin/env bash
set -Eeuo pipefail

readonly PRIVATE_REPOSITORY='mejechka/pokerops-bootstrap'
readonly APPLICATION_REPOSITORY='mejechka/po'
readonly GITHUB_OWNER='mejechka'
readonly PROJECT_REF='xpajqdsppawnjmvewkep'
readonly APPLICATION_COMMIT='1156eb3d1677d0ef3e9986a6f740c916245f8d41'
readonly WRAPPER_COMMIT='de86dd402d5466c702c1fd3ea65b3ef50e19913c'
readonly WRAPPER_SHA256='b21d1e8abbdaa4dfe0ab35bfaab3783f27b2fea9904f36b1b959f7a715a67b0d'
readonly PLANNER_PGSERVICE='pokerops-planner-migration'
readonly PG_SERVICE_FILE='/root/.pg_service.conf'
readonly INSTALL_ROOT='/opt/pokerops-tournament-ingestion'
readonly RUNTIME_ENV='/opt/pokerops-tournament-ingestion/shared/.env.tournament.local'
readonly MIGRATION_ENV='/opt/pokerops-tournament-ingestion/shared/.env.migration'
temporary_root=''
pg_service_temp=''
planner_pgservice=''
migration_host=''
migration_port=''
migration_user=''
migration_database=''
migration_sslmode=''

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

url_decode() {
  local input="$1" output='' prefix hex decoded
  while [[ "$input" == *%* ]]; do
    prefix="${input%%\%*}"
    output+="$prefix"
    input="${input#*%}"
    [[ "${#input}" -ge 2 ]] || return 1
    hex="${input:0:2}"
    [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ && "$hex" != '00' ]] || return 1
    printf -v decoded '%b' "\\x${hex}"
    output+="$decoded"
    input="${input:2}"
  done
  printf '%s' "${output}${input}"
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  unset PGPASSWORD
  if [[ -n "$pg_service_temp" && -f "$pg_service_temp" ]]; then
    [[ "$pg_service_temp" == /root/.pg_service.conf.tmp.* ]] || exit 1
    rm -f -- "$pg_service_temp"
  fi
  if [[ -n "$temporary_root" && -d "$temporary_root" ]]; then
    [[ "$temporary_root" == /tmp/pokerops-public-entrypoint.* ]] || exit 1
    rm -rf -- "$temporary_root"
  fi
  exit "$status"
}

load_migration_env_credentials() {
  local migration_url prefix remainder encoded_password endpoint authority_path query decoded_password
  [[ -f "$MIGRATION_ENV" && ! -L "$MIGRATION_ENV" ]] \
    || die 'sealed migration env is missing or is a symlink'
  [[ "$(stat -c '%U:%G:%a' "$MIGRATION_ENV")" == 'root:root:600' ]] \
    || die 'sealed migration env must be root:root mode 0600'
  [[ "$(grep -cE '^MIGRATION_DATABASE_URL=' "$MIGRATION_ENV")" == '1' ]] \
    || die 'sealed migration env must contain exactly one MIGRATION_DATABASE_URL'
  migration_url="$(env_value "$MIGRATION_ENV" MIGRATION_DATABASE_URL)"

  if [[ "$migration_url" == "postgresql://postgres.${PROJECT_REF}:"* ]]; then
    prefix="postgresql://postgres.${PROJECT_REF}:"
    migration_user="postgres.${PROJECT_REF}"
  elif [[ "$migration_url" == 'postgresql://postgres:'* ]]; then
    prefix='postgresql://postgres:'
    migration_user='postgres'
  else
    die 'MIGRATION_DATABASE_URL must use the PokerOps postgres role'
  fi
  remainder="${migration_url#"$prefix"}"
  [[ "$remainder" == *@* ]] || die 'MIGRATION_DATABASE_URL is malformed'
  endpoint="${remainder#*@}"
  [[ "$endpoint" != *@* ]] || die 'MIGRATION_DATABASE_URL contains an unescaped password character'
  encoded_password="${remainder%%@*}"
  [[ -n "$encoded_password" ]] || die 'MIGRATION_DATABASE_URL password is empty'
  [[ "$endpoint" == *\?* ]] || die 'MIGRATION_DATABASE_URL query parameters are missing'
  authority_path="${endpoint%%\?*}"
  query="${endpoint#*\?}"
  [[ "&${query}&" == *'&sslmode=require&'* ]] \
    || die 'MIGRATION_DATABASE_URL must require TLS'

  if [[ "$migration_user" == "postgres.${PROJECT_REF}" ]]; then
    [[ "$authority_path" =~ ^([A-Za-z0-9.-]+\.pooler\.supabase\.com):5432/postgres$ ]] \
      || die 'MIGRATION_DATABASE_URL must use Supabase session pooler port 5432'
    migration_host="${BASH_REMATCH[1]}"
  else
    [[ "$authority_path" == "db.${PROJECT_REF}.supabase.co:5432/postgres" ]] \
      || die 'direct MIGRATION_DATABASE_URL must target the PokerOps project on port 5432'
    migration_host="db.${PROJECT_REF}.supabase.co"
  fi
  decoded_password="$(url_decode "$encoded_password")" \
    || die 'MIGRATION_DATABASE_URL password encoding is invalid'
  [[ -n "$decoded_password" && "$decoded_password" != *$'\n'* && "$decoded_password" != *$'\r'* ]] \
    || die 'decoded migration password is invalid'
  migration_port='5432'
  migration_database='postgres'
  migration_sslmode='require'
  export PGPASSWORD="$decoded_password"
  unset decoded_password encoded_password migration_url remainder
}

ensure_pg_service_file() {
  if [[ -e "$PG_SERVICE_FILE" || -L "$PG_SERVICE_FILE" ]]; then
    return
  fi
  load_migration_env_credentials
  pg_service_temp="$(mktemp /root/.pg_service.conf.tmp.XXXXXX)"
  chmod 0600 "$pg_service_temp"
  chown root:root "$pg_service_temp"
  printf '%s\n' \
    "[${PLANNER_PGSERVICE}]" \
    "host=${migration_host}" \
    "port=${migration_port}" \
    "dbname=${migration_database}" \
    "user=${migration_user}" \
    "sslmode=${migration_sslmode}" \
    "application_name=pokerops_planner_migration" \
    >"$pg_service_temp"
  [[ ! -e "$PG_SERVICE_FILE" && ! -L "$PG_SERVICE_FILE" ]] \
    || die 'root pg_service file appeared during bootstrap'
  mv -- "$pg_service_temp" "$PG_SERVICE_FILE"
  pg_service_temp=''
}

validate_runtime_env() {
  local worker_url
  [[ -f "$RUNTIME_ENV" && ! -L "$RUNTIME_ENV" ]] \
    || die 'sealed runtime env is missing or is a symlink'
  [[ "$(stat -c '%U:%G:%a' "$RUNTIME_ENV")" == 'root:root:600' ]] \
    || die 'sealed runtime env must be root:root mode 0600'
  [[ "$(grep -cE '^DATABASE_URL=' "$RUNTIME_ENV")" == '1' ]] \
    || die 'sealed runtime env must contain exactly one DATABASE_URL'
  worker_url="$(env_value "$RUNTIME_ENV" DATABASE_URL)"
  [[ "$worker_url" == "postgresql://pokerops_tournament_worker.${PROJECT_REF}:"* ]] \
    || die 'worker DATABASE_URL is not for the expected restricted role'
  [[ "$worker_url" == *@* ]] || die 'worker DATABASE_URL is malformed'
  [[ "$worker_url" =~ ([?&])sslmode=require([&]|$) ]] \
    || die 'worker DATABASE_URL must require TLS'
}

pg_service_value() {
  local file="$1" service="$2" key="$3"
  awk -v wanted_section="$service" -v wanted_key="$key" '
    /^[[:space:]]*[#;]/ { next }
    /^[[:space:]]*\[/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      next
    }
    section == wanted_section && index($0, "=") > 0 {
      current_key = substr($0, 1, index($0, "=") - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", current_key)
      if (current_key == wanted_key) {
        value = substr($0, index($0, "=") + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
      }
    }
  ' "$file"
}

pg_service_sections() {
  awk '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      print section
    }
  ' "$PG_SERVICE_FILE"
}

approved_migration_service() {
  local service="$1" host port user database sslmode
  host="$(pg_service_value "$PG_SERVICE_FILE" "$service" host)"
  port="$(pg_service_value "$PG_SERVICE_FILE" "$service" port)"
  user="$(pg_service_value "$PG_SERVICE_FILE" "$service" user)"
  database="$(pg_service_value "$PG_SERVICE_FILE" "$service" dbname)"
  sslmode="$(pg_service_value "$PG_SERVICE_FILE" "$service" sslmode)"
  [[ "$database" == 'postgres' ]] || return 1
  [[ -z "$port" || "$port" == '5432' ]] || return 1
  [[ "$sslmode" == 'require' || "$sslmode" == 'verify-full' ]] || return 1
  if [[ "$host" == "db.${PROJECT_REF}.supabase.co" ]]; then
    [[ "$user" == 'postgres' ]]
  elif [[ "$host" == *.pooler.supabase.com ]]; then
    [[ "$user" == "postgres.${PROJECT_REF}" ]]
  else
    return 1
  fi
}

build_maintenance_url() {
  local password="$1" host port username
  host="$(pg_service_value "$PG_SERVICE_FILE" "$planner_pgservice" host)"
  port="$(pg_service_value "$PG_SERVICE_FILE" "$planner_pgservice" port)"
  [[ -n "$port" ]] || port='5432'
  if [[ "$host" == "db.${PROJECT_REF}.supabase.co" ]]; then
    username='pokerops_tournament_maintenance'
  elif [[ "$host" == *.pooler.supabase.com ]]; then
    username="pokerops_tournament_maintenance.${PROJECT_REF}"
  else
    die 'approved migration service host changed unexpectedly'
  fi
  printf 'postgresql://%s:%s@%s:%s/postgres?sslmode=require&application_name=pokerops-tournament-ingestion\n' \
    "$username" "$password" "$host" "$port"
}

resolve_migration_service() {
  local service approved_count=0
  [[ -f "$PG_SERVICE_FILE" && ! -L "$PG_SERVICE_FILE" ]] \
    || die 'root pg_service file is missing or is a symlink'
  [[ "$(stat -c '%U:%G:%a' "$PG_SERVICE_FILE")" == 'root:root:600' ]] \
    || die 'root pg_service file must be root:root mode 0600'
  export PGSERVICEFILE="$PG_SERVICE_FILE"

  if approved_migration_service "$PLANNER_PGSERVICE"; then
    planner_pgservice="$PLANNER_PGSERVICE"
    return
  fi
  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    if approved_migration_service "$service"; then
      planner_pgservice="$service"
      approved_count=$((approved_count + 1))
    fi
  done < <(pg_service_sections)
  [[ "$approved_count" == '1' ]] \
    || die 'pg_service file must contain exactly one approved PokerOps admin service'
}

ensure_migration_password() {
  local configured_password host port user database sslmode
  [[ -n "${PGPASSWORD:-}" ]] && return
  configured_password="$(pg_service_value "$PG_SERVICE_FILE" "$planner_pgservice" password)"
  [[ -z "$configured_password" ]] || return
  load_migration_env_credentials
  host="$(pg_service_value "$PG_SERVICE_FILE" "$planner_pgservice" host)"
  port="$(pg_service_value "$PG_SERVICE_FILE" "$planner_pgservice" port)"
  user="$(pg_service_value "$PG_SERVICE_FILE" "$planner_pgservice" user)"
  database="$(pg_service_value "$PG_SERVICE_FILE" "$planner_pgservice" dbname)"
  sslmode="$(pg_service_value "$PG_SERVICE_FILE" "$planner_pgservice" sslmode)"
  [[ -n "$port" ]] || port='5432'
  [[ "$host" == "$migration_host" && "$port" == "$migration_port" \
    && "$user" == "$migration_user" && "$database" == "$migration_database" \
    && "$sslmode" == "$migration_sslmode" ]] \
    || die 'sealed migration env does not match the approved pg_service endpoint'
}

validate_migration_service() {
  local role database can_manage_roles
  role="$(psql "service=${planner_pgservice}" -X -A -t -v ON_ERROR_STOP=1 -c 'select current_user')" \
    || die 'migration service role query failed'
  database="$(psql "service=${planner_pgservice}" -X -A -t -v ON_ERROR_STOP=1 -c 'select current_database()')" \
    || die 'migration service database query failed'
  can_manage_roles="$(psql "service=${planner_pgservice}" -X -A -t -v ON_ERROR_STOP=1 \
    -c "select (rolsuper or rolcreaterole)::text from pg_roles where rolname = current_user")" \
    || die 'migration service authority query failed'
  [[ "$role" != pokerops_tournament_worker* ]] || die 'migration service must not use the worker role'
  [[ "$database" == 'postgres' ]] || die 'migration service must target database postgres'
  [[ "$can_manage_roles" == 'true' || "$can_manage_roles" == 't' ]] \
    || die 'migration service cannot create the dedicated maintenance role'
}

validate_dependencies() {
  local required
  for required in bash curl git gh jq sha256sum pg_dump pg_restore psql docker flock df stat awk grep sed tar dd mktemp chmod chown; do
    command -v "$required" >/dev/null || die "required command is missing: ${required}"
  done
  docker compose version >/dev/null 2>&1 || die 'Docker Compose plugin is unavailable'
}

validate_github_access() {
  local resolved_application_sha
  gh auth status --hostname github.com >/dev/null 2>&1 \
    || die 'root GitHub CLI authentication is required'
  [[ "$(gh api user --jq '.login' 2>/dev/null)" == "$GITHUB_OWNER" ]] \
    || die 'root GitHub CLI must be authenticated as mejechka'
  [[ "$(gh api "repos/${PRIVATE_REPOSITORY}" --jq '.private and (.permissions.pull == true)' 2>/dev/null)" == 'true' ]] \
    || die 'private bootstrap repository access is required'
  resolved_application_sha="$(gh api "repos/${APPLICATION_REPOSITORY}/commits/${APPLICATION_COMMIT}" --jq '.sha' 2>/dev/null)" \
    || die 'exact application commit access is required'
  [[ "$resolved_application_sha" == "$APPLICATION_COMMIT" ]] \
    || die 'GitHub resolved an unexpected application commit'
}

validate_disk_space() {
  local database_size available required
  [[ -d "$INSTALL_ROOT" ]] || die 'Tournament ingestion install root is missing'
  database_size="$(psql "service=${planner_pgservice}" -X -A -t -v ON_ERROR_STOP=1 \
    -c 'select pg_database_size(current_database())::bigint')" \
    || die 'database size preflight failed'
  [[ "$database_size" =~ ^[0-9]+$ ]] || die 'database size preflight returned an invalid value'
  available="$(df -PB1 -- "$INSTALL_ROOT" | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4 }')" \
    || die 'backup filesystem free-space preflight failed'
  [[ "$available" =~ ^[0-9]+$ ]] || die 'backup filesystem free-space preflight returned an invalid value'
  required=$((database_size * 3 / 2))
  (( required >= 2147483648 )) || required=2147483648
  (( available >= required )) || die 'backup filesystem does not have enough free space'
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
      '  if exists (' \
      '    select 1' \
      '    from pg_roles' \
      "    where rolname = 'pokerops_tournament_maintenance'" \
      '      and (rolsuper or rolcreatedb or rolcreaterole or rolreplication or rolbypassrls)' \
      '  ) then' \
      "    raise exception 'existing maintenance role has forbidden privileges';" \
      '  end if;' \
      "  if not exists (select 1 from pg_roles where rolname = 'pokerops_tournament_maintenance') then" \
      '    create role pokerops_tournament_maintenance login nosuperuser nocreatedb nocreaterole' \
      '      noreplication nobypassrls inherit connection limit 1;' \
      '  end if;' \
      'end' \
      '$maintenance_role$;'
    printf "alter role pokerops_tournament_maintenance login inherit connection limit 1 password '%s';\n" "$password"
    printf '%s\n' \
      "alter role pokerops_tournament_maintenance set statement_timeout = '60s';" \
      "alter role pokerops_tournament_maintenance set lock_timeout = '5s';" \
      "alter role pokerops_tournament_maintenance set idle_in_transaction_session_timeout = '30s';" \
      'alter role pokerops_tournament_maintenance set search_path = public, pg_catalog;' \
      'commit;'
  } | psql "service=${planner_pgservice}" -X -v ON_ERROR_STOP=1 >/dev/null \
    || die 'maintenance role bootstrap failed'
}

seal_planner_runtime() {
  local maintenance_url="$1"
  if [[ "$maintenance_url" =~ ^postgresql://pokerops_tournament_maintenance\.${PROJECT_REF}:[0-9a-f]{64}@[A-Za-z0-9.-]+\.pooler\.supabase\.com:5432/postgres\? ]]; then
    :
  elif [[ "$maintenance_url" =~ ^postgresql://pokerops_tournament_maintenance:[0-9a-f]{64}@db\.${PROJECT_REF}\.supabase\.co:5432/postgres\? ]]; then
    :
  else
    die 'maintenance URL role or endpoint is invalid'
  fi
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
  local phase_a_wrapper maintenance_password maintenance_url
  [[ $# -eq 0 ]] || { printf 'usage: deploy.sh\n' >&2; exit 2; }
  [[ "$(id -u)" == '0' ]] || die 'run through sudo bash'
  [[ "$WRAPPER_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die 'wrapper commit must be immutable'

  umask 077
  trap cleanup EXIT INT TERM

  validate_dependencies
  validate_github_access
  validate_runtime_env
  ensure_pg_service_file
  resolve_migration_service
  ensure_migration_password
  validate_migration_service
  validate_disk_space

  temporary_root="$(mktemp -d /tmp/pokerops-public-entrypoint.XXXXXX)"
  phase_a_wrapper="$temporary_root/deploy.sh"
  gh api \
    -H 'Accept: application/vnd.github.raw+json' \
    "repos/${PRIVATE_REPOSITORY}/contents/deploy.sh?ref=${WRAPPER_COMMIT}" \
    >"$phase_a_wrapper"
  printf '%s  %s\n' "$WRAPPER_SHA256" "$phase_a_wrapper" | sha256sum -c - >/dev/null
  chmod 0700 "$phase_a_wrapper"

  maintenance_password="$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | sha256sum | awk '{print $1}')"
  provision_maintenance_role "$maintenance_password"
  maintenance_url="$(build_maintenance_url "$maintenance_password")"
  seal_planner_runtime "$maintenance_url"
  unset maintenance_password maintenance_url

  POKEROPS_PLANNER_PHASE_A_APPROVED=YES \
  POKEROPS_PLANNER_PGSERVICE="$planner_pgservice" \
    bash "$phase_a_wrapper"
}

if [[ "${POKEROPS_ENTRYPOINT_LIBRARY_ONLY:-0}" != '1' ]]; then
  main "$@"
fi
