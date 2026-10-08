#!/bin/sh
# Initializes the database on first boot, then starts the app.
#
# DB_INIT controls what happens when the database has no tables yet:
#   dump  (default) - restore asrs_db.sql (full snapshot with data)
#   empty           - load database/schema.sql + database/seed.sql
#   skip            - do nothing
set -e

if [ -z "$DATABASE_URL" ]; then
  echo "ERROR: DATABASE_URL is not set." >&2
  exit 1
fi

DB_INIT="${DB_INIT:-dump}"

if [ "$DB_INIT" != "skip" ]; then
  echo "Waiting for PostgreSQL..."
  i=0
  until psql "$DATABASE_URL" -tAc "SELECT 1" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then
      echo "ERROR: could not connect to PostgreSQL." >&2
      exit 1
    fi
    sleep 2
  done

  table_count=$(psql "$DATABASE_URL" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

  if [ "$table_count" = "0" ]; then
    case "$DB_INIT" in
      dump)
        echo "Empty database: restoring asrs_db.sql..."
        # Drop pg_dump 18 \restrict lines (not understood by older psql) and
        # OWNER statements (the dump's 'asrs' role does not exist on Railway).
        sed -e '/^\\restrict /d' -e '/^\\unrestrict /d' -e '/OWNER TO /d' asrs_db.sql \
          | psql "$DATABASE_URL" -q -o /dev/null
        ;;
      empty)
        echo "Empty database: loading schema and seed..."
        psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f database/schema.sql
        psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f database/seed.sql
        ;;
      *)
        echo "ERROR: unknown DB_INIT value '$DB_INIT'." >&2
        exit 1
        ;;
    esac
    echo "Database initialized."
  else
    echo "Database already has $table_count tables; skipping init."
  fi
fi

exec "$@"
