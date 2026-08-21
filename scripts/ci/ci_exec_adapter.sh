#!/bin/bash
# CI execution adapter — route a build/test script into the correct execution
# environment based on CI_EXECUTION_MODE (injected by the runner's local config).
#
#   legacy       (default) docker exec into CI_CONTAINER_NAME (default tilelang_x1)
#   host-wrapper write the script into GITHUB_WORKSPACE and run it through the
#                restricted CI_EXEC_WRAPPER (A3 host runner)
#
# Contract: reads the script path as $1. No eval, no hardcoded A3 container or
# device id, no sudo expansion beyond the configured wrapper. A2 keeps the
# legacy default when CI_EXECUTION_MODE is unset.
set -euo pipefail

SCRIPT="${1:?usage: ci_exec_adapter.sh <script-path>}"
MODE="${CI_EXECUTION_MODE:-legacy}"

case "${MODE}" in
  legacy)
    CONTAINER="${CI_CONTAINER_NAME:-tilelang_x1}"
    exec docker exec -i "${CONTAINER}" bash -s < "${SCRIPT}"
    ;;
  host-wrapper)
    WRAPPER="${CI_EXEC_WRAPPER:?CI_EXEC_WRAPPER is required}"
    WS="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
    TMP_SCRIPT="ci_exec_${GITHUB_RUN_ID:-0}_$$.sh"
    cp "${SCRIPT}" "${WS}/${TMP_SCRIPT}"
    chmod +x "${WS}/${TMP_SCRIPT}"
    trap 'rm -f "${WS}/${TMP_SCRIPT}"' EXIT
    exec sudo -n "${WRAPPER}" run "${WS}" "${TMP_SCRIPT}"
    ;;
  *)
    echo "ci_exec_adapter: unknown CI_EXECUTION_MODE=${MODE}" >&2
    exit 1
    ;;
esac
