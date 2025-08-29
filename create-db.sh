#!/bin/bash
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <name>"
  exit 1
fi

dbname="$1"
dbpass="${dbname}test"

# 1) Create role if it doesn't exist
if ! psql -v ON_ERROR_STOP=1 -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$dbname'" | grep -q 1; then
  psql -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$dbname\" LOGIN PASSWORD '$dbpass';"
else
  # ensure it has LOGIN and set (or reset) the password
  psql -v ON_ERROR_STOP=1 -c "ALTER ROLE \"$dbname\" LOGIN PASSWORD '$dbpass';"
fi

# 2) Create database if it doesn't exist (must be outside a transaction)
if ! psql -v ON_ERROR_STOP=1 -tAc "SELECT 1 FROM pg_database WHERE datname = '$dbname'" | grep -q 1; then
  psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$dbname\" OWNER \"$dbname\";"
fi

echo "✅ Role '$dbname' (password: ${dbpass}) and database '$dbname' are ready."

