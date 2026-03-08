#!/bin/bash

set -euo pipefail

if [[ -z "${VLLM_CI_BRANCH:-}" ]]; then
    VLLM_CI_BRANCH="main"
fi

if [[ -z "${VLLM_CI_INFRA_BRANCH:-}" ]]; then
    VLLM_CI_INFRA_BRANCH="$VLLM_CI_BRANCH"
fi

if [[ -f .buildkite/.pipeline_gen_v2 ]]; then
    echo "Detected .pipeline_gen_v2, using pipeline generator flow."

    python -m pip install --user \
        "git+https://github.com/vllm-project/ci-infra.git@${VLLM_CI_INFRA_BRANCH}#subdirectory=buildkite/pipeline_generator"

    if [[ ! -f .buildkite/hardware_tests/intel.yaml ]]; then
        echo "ERROR: required vLLM test definition not found: .buildkite/hardware_tests/intel.yaml"
        exit 1
    fi

    mkdir -p .buildkite/.intel_ci/jobs

    # Keep test cases sourced from vLLM upstream repo, not from ci-infra.
    cp .buildkite/hardware_tests/intel.yaml .buildkite/.intel_ci/jobs/intel.yaml

    # Use a minimal config that points generator to the copied vLLM job file.
    cat > .buildkite/.intel_ci/ci_config.yaml <<'EOF'
name: vllm_ci
github_repo_name: vllm-project/vllm
job_dirs:
  - ".buildkite/.intel_ci/jobs"
run_all_patterns:
  - "docker/Dockerfile"
  - "CMakeLists.txt"
  - "requirements/common.txt"
  - "requirements/cuda.txt"
  - "requirements/build.txt"
  - "requirements/test.txt"
  - "setup.py"
  - "csrc/"
  - "cmake/"
run_all_exclude_patterns:
  - "docker/Dockerfile."
  - "csrc/cpu/"
  - "csrc/rocm/"
  - "cmake/hipify.py"
  - "cmake/cpu_extension.cmake"
registries: public.ecr.aws/q9t5s3a7
repositories:
  main: "vllm-ci-postmerge-repo"
  premerge: "vllm-ci-test-repo"
EOF

    PIPELINE_GENERATOR_BIN="/var/lib/buildkite-agent/.local/bin/pipeline-generator"
    if [[ ! -x "$PIPELINE_GENERATOR_BIN" ]]; then
        PIPELINE_GENERATOR_BIN="$(command -v pipeline-generator || true)"
    fi

    if [[ -z "${PIPELINE_GENERATOR_BIN:-}" ]]; then
        echo "ERROR: pipeline-generator not found after install"
        exit 1
    fi

    "$PIPELINE_GENERATOR_BIN" \
        --pipeline_config_path .buildkite/.intel_ci/ci_config.yaml \
        --output_file_path .buildkite/pipeline.yaml

    if [[ -f .buildkite/.docs_only ]]; then
        echo "docs-only change detected by pipeline generator, skipping upload"
        exit 0
    fi

    buildkite-agent artifact upload .buildkite/pipeline.yaml
    buildkite-agent pipeline upload .buildkite/pipeline.yaml
    exit 0
fi

echo "No .pipeline_gen_v2 marker found, falling back to upstream bootstrap.sh"
TMP_BOOTSTRAP="$(mktemp)"
trap 'rm -f "$TMP_BOOTSTRAP"' EXIT
curl -fsSL "https://raw.githubusercontent.com/vllm-project/ci-infra/${VLLM_CI_INFRA_BRANCH}/buildkite/bootstrap.sh" -o "$TMP_BOOTSTRAP"
VLLM_CI_BRANCH="$VLLM_CI_BRANCH" bash "$TMP_BOOTSTRAP"
