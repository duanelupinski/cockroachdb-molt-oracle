#!/bin/bash
# Load local connection settings. Source this; do not execute it.
if [[ -z "${ORACLE_ENV_LOADED:-}" ]]; then
  ORACLE_ENV_LOADED=1
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ ! -f "${REPO_ROOT}/.env" ]]; then
    cp "${REPO_ROOT}/.env.example" "${REPO_ROOT}/.env"
    echo "Created ${REPO_ROOT}/.env from .env.example"
  fi
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
  CONTAINER_NAME="${CONTAINER_NAME:-oracle-source}"
  IMAGE_NAME="${IMAGE_NAME:-oracle-hr-source:local}"
  ORACLE_PORT="${ORACLE_PORT:-1521}"
  ORACLE_SERVICE="${ORACLE_SERVICE:-FREEPDB1}"
  HR_TABLESPACE="${HR_TABLESPACE:-USERS}"
fi
