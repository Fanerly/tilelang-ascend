#!/bin/bash
# A3 Host Runner full canary orchestration.
#
# Runs inside tl_fzh via the host wrapper (uid 1004 gid 1000), with the current
# GitHub checkout as the working directory. It must NOT import the prebuilt
# stable repo /workspace/fzh/tilelang-ascend; every tilelang/tvm import must
# resolve to the current checkout.
#
# Phases (fail-fast, each writing its own log):
#   env -> submodule -> full build -> verify -> incremental build
#        -> benchmark -> main pytest -> tail-block isolated -> operator isolated
set -euo pipefail

REPO="$(pwd -P)"
export REPO
cd "${REPO}"

source /usr/local/Ascend/cann-9.1.0-beta.1/set_env.sh
source /workspace/fzh/venvs/tilelang-a3-host-py312/bin/activate

export USER="$(id -un)"
export LOGNAME="${USER}"
export ASCEND_RT_VISIBLE_DEVICES="${ASCEND_RT_VISIBLE_DEVICES:-0}"
CPUSET="${CI_CPUSET:-0-15}"

P="a3_host"
RUNTMP="$(mktemp -d "${TMPDIR:-/tmp}/a3host.XXXXXX")"

# Run context written by the workflow step (github.run_id / job / matrix.validation_run).
RUN_ID="unknown"
VALIDATION_RUN="0"
if [ -f "${REPO}/a3_host_run_ctx.env" ]; then
  # shellcheck disable=SC1090
  source "${REPO}/a3_host_run_ctx.env"
fi

# Persist logs outside the checkout so the next round's checkout clean cannot
# wipe run-N evidence. Isolated by run_id + validation_run.
LOG_DIR="/workspace/fzh/gha-fzh-log/a3-host-canary-r${RUN_ID}-n${VALIDATION_RUN}"
mkdir -p "${LOG_DIR}"

trap 'cp -f "${REPO}"/a3_host_*.log "${LOG_DIR}"/ 2>/dev/null || true; rm -rf "${RUNTMP}"' EXIT

# ---------------------------------------------------------------------------
# env snapshot
# ---------------------------------------------------------------------------
{
  echo "repo=${REPO}"
  echo "id=$(id -u):$(id -g) user=$(id -un) group=$(id -gn)"
  echo "python=$(which python)"
  echo "python_version=$(python --version 2>&1)"
  echo "CANN=${ASCEND_HOME_PATH:-unset}"
  echo "torch=$(python -c 'import torch; print(torch.__version__)' 2>&1)"
  echo "torch_npu=$(python -c 'import torch_npu; print(torch_npu.__version__)' 2>&1)"
  echo "ASCEND_RT_VISIBLE_DEVICES=${ASCEND_RT_VISIBLE_DEVICES}"
  echo "device_count=$(python -c 'import torch; print(torch.npu.device_count())' 2>&1)"
  echo "TMPDIR=${TMPDIR:-unset}"
} | tee "${P}_env.log"

# ---------------------------------------------------------------------------
# Phase 1: recursive submodule init (HTTP/1.1, bounded low-speed, 3 attempts)
# ---------------------------------------------------------------------------
echo "=== PHASE submodule ==="
{
  git config --local http.version HTTP/1.1
  git config --local http.lowSpeedLimit 1
  git config --local http.lowSpeedTime 600

  git submodule sync --recursive

  SUBMODULE_OK=false
  for attempt in 1 2 3; do
    echo "submodule attempt ${attempt}/3"
    if git \
      -c http.version=HTTP/1.1 \
      -c http.lowSpeedLimit=1 \
      -c http.lowSpeedTime=600 \
      submodule update --init --recursive --jobs 2 --depth 1; then
      SUBMODULE_OK=true
      break
    fi
    sleep 5
  done
  [ "${SUBMODULE_OK}" = true ] || { echo "submodule update failed after 3 attempts"; exit 1; }

  git submodule status --recursive | tee "${P}_submodules.log"
  if git submodule status --recursive | grep -Eq '^[-+]'; then
    echo "submodule state incomplete or mismatched"
    exit 1
  fi
  echo "SUBMODULE_OK"
} 2>&1 | tee -a "${P}_submodules.log"
test "${PIPESTATUS[0]}" -eq 0

# ---------------------------------------------------------------------------
# Phase 2: full clean build
# ---------------------------------------------------------------------------
echo "=== PHASE full build ==="
export MAKEFLAGS="--output-sync=target"
set +e
taskset -c "${CPUSET}" bash install_ascend.sh 2>&1 | tee "${P}_build.log"
BUILD_RC=${PIPESTATUS[0]}
set -e

if [ "${BUILD_RC}" -ne 0 ]; then
  echo "full build FAILED rc=${BUILD_RC}; running serial verbose diagnostic" | tee -a "${P}_build.log"
  if [ -d "${REPO}/build" ]; then
    ( cd "${REPO}/build" && \
      MAKEFLAGS="--output-sync=target" make VERBOSE=1 -j1 2>&1 \
      | tee "${REPO}/${P}_build_diag.log" ) || true
  else
    echo "no build directory for diagnostic" | tee "${REPO}/${P}_build_diag.log"
  fi
  echo "diagnostic done; returning original build rc=${BUILD_RC}"
  exit "${BUILD_RC}"
fi

# ---------------------------------------------------------------------------
# Phase 3: verify tilelang/tvm resolve to the current checkout (not stable repo)
# ---------------------------------------------------------------------------
echo "=== PHASE verify ==="
source "${REPO}/set_env.sh"
python - <<'PY' 2>&1 | tee "${P}_verify.log"
import os
import tilelang
import tvm
import torch
import torch_npu

repo = os.path.realpath(os.environ["REPO"])
tl = os.path.realpath(tilelang.__file__)
tv = os.path.realpath(tvm.__file__)

print("tilelang", tl)
print("tvm", tv)
print("torch", torch.__version__)
print("torch_npu", torch_npu.__version__)
print("device_count", torch.npu.device_count())

assert tl.startswith(repo + os.sep), "tilelang NOT from checkout: %s" % tl
assert tv.startswith(repo + os.sep), "tvm NOT from checkout: %s" % tv
assert torch.npu.is_available() is True
assert torch.npu.device_count() == 1
print("VERIFY_OK")
PY
test "${PIPESTATUS[0]}" -eq 0

# ---------------------------------------------------------------------------
# Phase 4: incremental build
# ---------------------------------------------------------------------------
echo "=== PHASE incremental build ==="
taskset -c "${CPUSET}" bash install_ascend.sh --enable-incremental 2>&1 | tee "${P}_incremental.log"
test "${PIPESTATUS[0]}" -eq 0

# ---------------------------------------------------------------------------
# Phase 5: complete benchmark (skip pytest)
# ---------------------------------------------------------------------------
echo "=== PHASE benchmark ==="
(
  cd examples
  set +e
  bash bench_test.sh --skip-pytest 2>&1 | tee "${REPO}/${P}_bench.log"
  rc=${PIPESTATUS[0]}
  set -e
  grep -E 'Total:|Passed:|Failed:|Pass rate:' "${REPO}/${P}_bench.log" || true
  exit "${rc}"
)
test $? -eq 0

# ---------------------------------------------------------------------------
# Phase 6: main pytest (no --forked; tail-block and operator run separately)
# ---------------------------------------------------------------------------
echo "=== PHASE main pytest ==="
TAIL_FILE="testing/python/language/test_tilelang_ascend_language_tail_block.py"
mkdir -p "${RUNTMP}/main"
set +e
pytest testing/python/ \
  --ignore="${TAIL_FILE}" \
  -v -n 2 \
  -m "not ci_skip" \
  --basetemp="${RUNTMP}/main" \
  2>&1 | tee "${P}_pytest.log"
PYTEST_RC=${PIPESTATUS[0]}
set -e
[ "${PYTEST_RC}" -eq 0 ] || { echo "main pytest failed rc=${PYTEST_RC}"; exit 1; }

# ---------------------------------------------------------------------------
# Phase 7: tail-block tests in isolated processes (max 3 attempts each)
# ---------------------------------------------------------------------------
echo "=== PHASE tail-block ==="
mapfile -t TAIL_NODES < <(
  pytest --collect-only -q "${TAIL_FILE}" -m "not ci_skip" |
    grep -F "${TAIL_FILE}::"
)
total=${#TAIL_NODES[@]}
[ "${total}" -gt 0 ] || { echo "no tail-block nodes collected"; exit 1; }

MAX_ATTEMPTS=3
passed=0
flaky=0
failed=0
index=0
for node in "${TAIL_NODES[@]}"; do
  index=$((index + 1))
  node_passed=false
  attempt=1
  while [ "${attempt}" -le "${MAX_ATTEMPTS}" ]; do
    {
      echo
      echo "[${index}/${total}] ${node}"
      echo "Attempt ${attempt}/${MAX_ATTEMPTS}"
    } | tee -a "${P}_tail.log"

    if pytest -q "${node}" -m "not ci_skip" \
      --basetemp="${RUNTMP}/tail_${index}_${attempt}" >> "${P}_tail.log" 2>&1; then
      node_passed=true
      passed=$((passed + 1))
      if [ "${attempt}" -eq 1 ]; then
        echo "[PASSED] ${node}" | tee -a "${P}_tail.log"
      else
        flaky=$((flaky + 1))
        echo "[FLAKY-PASSED] ${node} on attempt ${attempt}" | tee -a "${P}_tail.log"
      fi
      break
    fi
    echo "[ATTEMPT FAILED] ${node} attempt=${attempt}" | tee -a "${P}_tail.log"
    attempt=$((attempt + 1))
  done

  if [ "${node_passed}" != true ]; then
    failed=$((failed + 1))
    echo "[PERSISTENT-FAILED] ${node} after ${MAX_ATTEMPTS} attempts" | tee -a "${P}_tail.log"
  fi
done

{
  echo
  echo "tail-block summary: total=${total} passed=${passed} flaky=${flaky} persistent_failed=${failed}"
} | tee -a "${P}_tail.log"
[ "${failed}" -eq 0 ] || { echo "tail-block persistent failures: ${failed}"; exit 1; }

# ---------------------------------------------------------------------------
# Phase 8: operator tests in isolated file processes
# ---------------------------------------------------------------------------
echo "=== PHASE operator ==="
mapfile -t OPERATOR_TESTS < <(
  python scripts/ci/resolve_operator_tests.py list-tests | sed '/^[[:space:]]*$/d'
)
total_files=${#OPERATOR_TESTS[@]}
echo "operator test files: ${total_files}" | tee "${P}_operator.log"

passed_files=0
failed_files=0
index=0
for operator_test in "${OPERATOR_TESTS[@]}"; do
  index=$((index + 1))
  {
    echo
    echo "[${index}/${total_files}] ${operator_test}"
  } | tee -a "${P}_operator.log"

  if pytest "${operator_test}" -v -m "not ci_skip" \
    --basetemp="${RUNTMP}/op_${index}" >> "${P}_operator.log" 2>&1; then
    passed_files=$((passed_files + 1))
    echo "[PASSED FILE] ${operator_test}" | tee -a "${P}_operator.log"
  else
    failed_files=$((failed_files + 1))
    echo "[FAILED FILE] ${operator_test}" | tee -a "${P}_operator.log"
  fi
done

{
  echo
  echo "operator summary: total_files=${total_files} passed=${passed_files} failed=${failed_files}"
} | tee -a "${P}_operator.log"
[ "${failed_files}" -eq 0 ] || { echo "operator failed files: ${failed_files}"; exit 1; }

echo "FULL_CANARY_OK"
