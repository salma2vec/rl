#!/usr/bin/env bash

set -euxo pipefail

export ACCEPT_EULA=Y
export OMNI_KIT_ACCEPT_EULA=YES
export PRIVACY_CONSENT=Y
export BATCHED_PIPE_TIMEOUT=60
export TD_GET_DEFAULTS_TO_NONE=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PYTHONNOUSERSITE=1
export RAY_ENABLE_UV_RUN_RUNTIME_ENV=0

nvidia-smi

git config --global --add safe.directory '*'
root_dir="$(git rev-parse --show-toplevel)"
cd "${root_dir}"

PYTHON="${VIRTUAL_ENV:-/opt/isaaclab-venv}/bin/python"
"${PYTHON}" -m pip freeze --all > "${root_dir}/isaaclab-image-freeze.txt"
"${PYTHON}" - <<'PY'
import importlib.metadata as metadata

import torch

isaaclab_version = metadata.version("isaaclab")
print(f"isaaclab {isaaclab_version}, torch {torch.__version__} (CUDA {torch.version.cuda})")
assert isaaclab_version.startswith("3."), isaaclab_version
assert torch.version.cuda and torch.version.cuda.startswith("13."), torch.version.cuda
assert torch.cuda.is_available()
PY

printf "* Installing tensordict\n"
if [[ "${RELEASE:-0}" == 0 ]]; then
  "${PYTHON}" -m pip install --no-deps git+https://github.com/pytorch/tensordict.git
else
  "${PYTHON}" -m pip install --no-deps "tensordict>=0.15.2,<0.16.0"
fi
"${PYTHON}" -m pip install cloudpickle "pyvers>=0.2.3,<0.3.0" "hoptorch>=0.1.4" "pybind11[global]" ninja

printf "* Installing torchrl\n"
"${PYTHON}" -m pip install -e . --no-build-isolation --no-deps
"${PYTHON}" - <<'PY'
import pathlib

import torch
import torchrl

print(f"torchrl from {torchrl.__file__}, torch {torch.__version__}")
assert pathlib.Path(torchrl.__file__).resolve().is_relative_to(pathlib.Path.cwd().resolve())
assert torch.version.cuda.startswith("13."), torch.version.cuda
PY

"${PYTHON}" -m pip install pytest-timeout pytest-rerunfailures ray

TEST_IDS=$("${PYTHON}" -m pytest test/libs/test_isaac.py -k isaaclab --collect-only -q 2>/dev/null | grep "::")
if [[ -z "${TEST_IDS}" ]]; then
  echo "ERROR: no Isaac Lab tests collected"
  exit 1
fi

OVERALL=0
while IFS= read -r TEST_ID; do
  [[ -z "${TEST_ID}" ]] && continue
  echo "Running: ${TEST_ID}"
  if ! "${PYTHON}" -m pytest "${TEST_ID}" -s --timeout=900; then
    echo "TEST FAILED: ${TEST_ID}"
    OVERALL=1
  fi
done <<< "${TEST_IDS}"
exit "${OVERALL}"
