#!/bin/bash
set -e

# Prepare PostgreSQL data directory permissions
mkdir -p "$PGDATA"
chown postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"

# Start Patroni as the postgres operating-system user
exec gosu postgres patroni "$@"