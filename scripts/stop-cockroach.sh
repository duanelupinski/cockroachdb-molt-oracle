#!/bin/bash
# Stop the CockroachDB nodes. Data volumes are kept.
set -euo pipefail

for name in crdb1 crdb2 crdb3; do
  if podman container exists "${name}"; then
    podman stop "${name}"
    echo "Stopped ${name}."
  else
    echo "Container ${name} does not exist."
  fi
done
