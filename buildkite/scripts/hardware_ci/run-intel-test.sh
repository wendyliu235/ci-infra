#!/bin/bash

# Intel XPU test wrapper for Buildkite.
# Purpose:
# 1) Normalize command passing (prefer VLLM_TEST_COMMANDS).
# 2) Provide consistent docker run options for Intel GPU nodes.
# 3) Keep cleanup/retry behavior predictable.
set -euo pipefail

handle_pytest_exit() {
  local exit_code="$1"
  if [[ "$exit_code" -eq 5 ]]; then
    echo "Pytest exit code 5 (no tests collected), treating as success"
    exit 0
  fi
  exit "$exit_code"
}

re_quote_pytest_markers() {
  local input="$1"
  local output=""
  local collecting=false
  local marker_buf=""

  local flat="${input//$'\\\n'/ }"
  flat="${flat//$'\n'/ }"

  local restore_glob
  restore_glob="$(shopt -p -o noglob 2>/dev/null || true)"
  set -o noglob
  local -a words
  read -ra words <<< "$flat"
  eval "$restore_glob"

  for word in "${words[@]}"; do
    if $collecting; then
      local is_boundary=false
      case "$word" in
        "\\"|"&&"|"||"|";"|"|") is_boundary=true ;;
        --*) is_boundary=true ;;
        -[a-zA-Z]) is_boundary=true ;;
        */*) is_boundary=true ;;
        *.py|*.py::*) is_boundary=true ;;
        *=*)
          if [[ "$word" =~ ^[A-Z_][A-Z0-9_]*= ]]; then
            is_boundary=true
          fi
          ;;
      esac

      if $is_boundary; then
        if [[ -n "$marker_buf" ]]; then
          if [[ "$marker_buf" == *" "* || "$marker_buf" == *"("* ]]; then
            output+="'${marker_buf}' "
          else
            output+="${marker_buf} "
          fi
        fi
        collecting=false
        marker_buf=""
        if [[ "$word" == "-m" || "$word" == "-k" ]]; then
          output+="${word} "
          collecting=true
        elif [[ "$word" != "\\" ]]; then
          output+="${word} "
        fi
      else
        if [[ -n "$marker_buf" ]]; then
          marker_buf+=" ${word}"
        else
          marker_buf="${word}"
        fi
      fi
    elif [[ "$word" == "-m" || "$word" == "-k" ]]; then
      output+="${word} "
      collecting=true
      marker_buf=""
    else
      output+="${word} "
    fi
  done

  if $collecting && [[ -n "$marker_buf" ]]; then
    if [[ "$marker_buf" == *" "* || "$marker_buf" == *"("* ]]; then
      output+="'${marker_buf}'"
    else
      output+="${marker_buf}"
    fi
  fi

  echo "${output% }"
}

apply_intel_test_overrides() {
  # Placeholder for Intel-specific ignores/env rewrites if needed later.
  echo "$1"
}

if [[ "${NUM_NODES:-1}" -gt 1 ]]; then
  echo "ERROR: Multi-node mode is not implemented for run-intel-test.sh yet (NUM_NODES=${NUM_NODES})."
  exit 2
fi

if [[ -n "${VLLM_TEST_COMMANDS:-}" ]]; then
  commands="${VLLM_TEST_COMMANDS}"
  echo "Commands sourced from VLLM_TEST_COMMANDS"
else
  commands="$*"
  if [[ -z "$commands" ]]; then
    echo "Error: no test commands provided"
    echo "Usage: VLLM_TEST_COMMANDS='...' bash .buildkite/scripts/hardware_ci/run-intel-test.sh"
    exit 1
  fi
  echo "Commands sourced from positional args"
fi

commands="$(re_quote_pytest_markers "$commands")"
commands="$(apply_intel_test_overrides "$commands")"

echo "Final commands: $commands"

if [[ ! -e /dev/dri ]]; then
  echo "ERROR: /dev/dri does not exist on this host"
  exit 1
fi

IMAGE_NAME="${INTEL_XPU_IMAGE:-intel/vllm:0.14.1-xpu}"
CONTAINER_NAME="intel_xpu_${BUILDKITE_COMMIT:-local}_$(tr -dc A-Za-z0-9 </dev/urandom | head -c 10; echo)"
HF_CACHE="${HF_CACHE:-$(realpath ~)/huggingface}"
HF_MOUNT="/root/.cache/huggingface"
mkdir -p "$HF_CACHE"

echo "Pulling image: ${IMAGE_NAME}"
docker pull "${IMAGE_NAME}"

cleanup_container() {
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
}
trap cleanup_container EXIT

RDMA_FLAGS=""
if [[ -d /dev/infiniband ]]; then
  RDMA_FLAGS="--device /dev/infiniband --cap-add=IPC_LOCK"
fi

docker run \
  --device /dev/dri:/dev/dri \
  -v /dev/dri/by-path:/dev/dri/by-path \
  ${RDMA_FLAGS} \
  --network=host \
  --ipc=host \
  --privileged \
  --rm \
  --entrypoint "" \
  -e HF_TOKEN \
  -e ZE_AFFINITY_MASK \
  -e "HF_HOME=${HF_MOUNT}" \
  -e "PYTHONPATH=.." \
  -e "VLLM_TEST_COMMANDS=${commands}" \
  -v "${HF_CACHE}:${HF_MOUNT}" \
  --name "${CONTAINER_NAME}" \
  "${IMAGE_NAME}" \
  bash -lc 'set -euo pipefail; cd /vllm-workspace/tests 2>/dev/null || cd /vllm-workspace 2>/dev/null || true; eval "$VLLM_TEST_COMMANDS"'

exit_code=$?
handle_pytest_exit "$exit_code"
