#!/usr/bin/env bash
set -euo pipefail
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  DO \$\$
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${PG_EXPORTER_USER:-monitoring}') THEN
      CREATE ROLE ${PG_EXPORTER_USER:-monitoring} LOGIN PASSWORD '${PG_EXPORTER_PASSWORD:-change-me-pg-readonly}';
    END IF;
  END
  \$\$;
  GRANT pg_monitor TO ${PG_EXPORTER_USER:-monitoring};
EOSQL
