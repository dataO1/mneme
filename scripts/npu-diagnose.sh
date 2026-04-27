#!/usr/bin/env bash
# NPU diagnostic harness for mneme. Bisects "is the NPU working at all" vs
# "is the bge-base model the problem". Run individual stages with the first
# argument, or no args to run all three in order.
#
# Usage:
#   ./scripts/npu-diagnose.sh           # run all stages
#   ./scripts/npu-diagnose.sh device    # 1: probe NPU plugin from container
#   ./scripts/npu-diagnose.sh compile   # 2: compile + run a trivial model
#   ./scripts/npu-diagnose.sh minilm    # 3: try all-MiniLM-L6-v2 on NPU
#   ./scripts/npu-diagnose.sh debug     # 4: re-serve current model with debug logs
#
# Requires: rootful podman, /dev/accel/accel0, render+video groups on host.

set -euo pipefail

# The OVMS runtime image is stripped down to the serving binary (no python3
# in PATH), so device/compile probes use the OpenVINO dev image, which ships
# python3 + openvino bindings + benchmark_app. The minilm + debug stages
# stick with the model_server image since they test that exact serving path.
OVMS_IMAGE="${OVMS_IMAGE:-openvino/model_server:2026.0-gpu}"
OV_DEV_IMAGE="${OV_DEV_IMAGE:-openvino/ubuntu24_dev:2026.0.0}"
RENDER_GID="$(getent group render | cut -d: -f3)"
VIDEO_GID="$(getent group video  | cut -d: -f3)"
TEST_MODELS_DIR="${TEST_MODELS_DIR:-/tmp/mneme-npu-test}"

if [ -z "$RENDER_GID" ] || [ -z "$VIDEO_GID" ]; then
  echo "ERROR: render or video group not in /etc/group" >&2
  exit 2
fi

if [ ! -c /dev/accel/accel0 ]; then
  echo "ERROR: /dev/accel/accel0 missing — intel_vpu driver not loaded?" >&2
  exit 2
fi

# Common podman flags for NPU passthrough. --workdir /tmp avoids a podman
# overlayfs glitch when an image's WORKDIR collides with a baked-in path
# (the openvino dev image sets WORKDIR=/opt/intel/openvino, and overlayfs
# on this storage refuses to mkdir over the existing dir at run time).
podman_npu() {
  sudo podman run --rm -i \
    --device=/dev/accel/accel0 \
    --group-add="$RENDER_GID" \
    --group-add="$VIDEO_GID" \
    --user=0:0 \
    --workdir /tmp \
    "$@"
}

# Run a Python snippet inside the OpenVINO dev image with NPU passthrough.
# Reads stdin as the script body.
ov_python() {
  podman_npu \
    --entrypoint /bin/bash \
    "$OV_DEV_IMAGE" \
    -lc 'python3 -'
}

stage_device() {
  echo "=== [1/3] NPU plugin probe (image: $OV_DEV_IMAGE) ==="
  echo "Expecting 'Devices: [...,NPU,...]' and a non-empty FULL_DEVICE_NAME."
  echo
  ov_python <<'PY'
import openvino as ov
core = ov.Core()
print("Devices:", core.available_devices)
if "NPU" in core.available_devices:
    print("NPU full name:", core.get_property("NPU", "FULL_DEVICE_NAME"))
    try:
        print("NPU driver version:", core.get_property("NPU", "NPU_DRIVER_VERSION"))
    except Exception as e:
        print("NPU driver version: <unavailable>", e)
else:
    print("FAIL: NPU not in available devices — plugin or device passthrough is broken.")
PY
  echo
}

stage_compile() {
  echo "=== [2/3] Trivial-model compile + inference on NPU (image: $OV_DEV_IMAGE) ==="
  echo "Expecting 'compiled on NPU OK' and 'inference shape: (1, 32)'."
  echo
  ov_python <<'PY'
import numpy as np
import openvino as ov

# OpenVINO 2026 moved opset12 out of openvino.runtime; try both.
try:
    import openvino.opset12 as ops
except ImportError:
    import openvino.runtime.opset12 as ops

# 1-op MatMul, fully static shapes. If this fails, the NPU compiler is broken
# in this image build (or the silicon does not support a basic MatMul, which
# would be a serious driver/firmware issue).
inp = ops.parameter([1, 32], dtype=np.float32, name="x")
w   = ops.constant(np.random.randn(32, 32).astype(np.float32))
out = ops.matmul(inp, w, transpose_a=False, transpose_b=False)
model = ov.Model([out], [inp], "tiny")

core = ov.Core()
compiled = core.compile_model(model, "NPU")
print("compiled on NPU OK")

result = compiled([np.random.randn(1, 32).astype(np.float32)])
print("inference shape:", result[compiled.output(0)].shape)
PY
  echo
}

stage_minilm() {
  echo "=== [3/3] Try all-MiniLM-L6-v2 on NPU (smaller embed model than bge-base) ==="
  echo "Expecting 'Model: ... downloaded to ...' and a graph.pbtxt write,"
  echo "no 'Cannot compile model into target device'."
  echo
  mkdir -p "$TEST_MODELS_DIR"
  chmod 777 "$TEST_MODELS_DIR"

  # OVMS only accepts CLS or LAST pooling for embeddings (not MEAN, even
  # though all-MiniLM-L6-v2 was trained with MEAN). For the diagnostic we
  # just want to know if the NPU compile path works on a smaller embedding
  # model — quality of the resulting vectors doesn't matter here.
  podman_npu \
    -v "$TEST_MODELS_DIR":/models:rw \
    "$OVMS_IMAGE" \
    --pull \
    --model_repository_path /models \
    --source_model sentence-transformers/all-MiniLM-L6-v2 \
    --task embeddings \
    --pooling CLS \
    --target_device NPU || {
      echo
      echo "--- minilm pull failed; rerun with target_device CPU to confirm pull itself works:"
      podman_npu \
        -v "$TEST_MODELS_DIR":/models:rw \
        "$OVMS_IMAGE" \
        --pull \
        --model_repository_path /models \
        --source_model sentence-transformers/all-MiniLM-L6-v2 \
        --task embeddings --pooling CLS \
        --target_device CPU
    }
  echo
}

stage_serve_minilm() {
  echo "=== [3b] Serve all-MiniLM-L6-v2 on NPU and watch for compile ==="
  echo "Looks for either 'state changed to: AVAILABLE' (NPU compile worked)"
  echo "or 'Cannot compile model into target device' (same failure as bge-base)."
  echo "Runs for ~30 s, then SIGTERMs the container. Binds 8002 (no clash)."
  echo

  if [ ! -d "$TEST_MODELS_DIR/sentence-transformers/all-MiniLM-L6-v2" ]; then
    echo "FAIL: minilm model not pulled — run './$0 minilm' first." >&2
    return 1
  fi

  # Symlink to a name OVMS resolves cleanly (its mediapipe loader looks for
  # files at <repo>/<mediapipe.name>/...).
  sudo ln -sfnT sentence-transformers/all-MiniLM-L6-v2 "$TEST_MODELS_DIR/embeddings"
  sudo tee "$TEST_MODELS_DIR/config.json" > /dev/null <<'EOF'
{
  "model_config_list": [],
  "mediapipe_config_list": [
    { "name": "embeddings", "graph_path": "/models/embeddings/graph.pbtxt" }
  ]
}
EOF

  # `timeout` SIGKILLs after 30 s; podman run inherits and the container exits.
  timeout 30 sudo podman run --rm -i \
    --device=/dev/accel/accel0 \
    --group-add="$RENDER_GID" \
    --group-add="$VIDEO_GID" \
    --user=0:0 \
    --workdir /tmp \
    -v "$TEST_MODELS_DIR":/models:ro \
    -p 127.0.0.1:8002:8000 \
    "$OVMS_IMAGE" \
    --rest_port 8000 \
    --config_path /models/config.json \
    --log_level DEBUG 2>&1 \
  | grep --line-buffered -iE 'available devices|state changed|cannot compile|target_device|compile model|fallback|npu|vcl_serializer' \
  | head -50
  echo
  echo "(timeout reached or container exited)"
}

stage_debug() {
  echo "=== [4] Re-serve current bge-base config at debug log level ==="
  echo "Watch for the full NPU compile error chain. Ctrl-C to stop."
  echo "(This binds 8001:8000 so it doesn't clash with the live mneme OVMS.)"
  echo
  podman_npu \
    -v /var/lib/mneme/ovms-models:/models:ro \
    -p 127.0.0.1:8001:8000 \
    "$OVMS_IMAGE" \
    --rest_port 8000 \
    --config_path /models/config.json \
    --log_level DEBUG
}

case "${1:-all}" in
  device)        stage_device ;;
  compile)       stage_compile ;;
  minilm)        stage_minilm ;;
  serve-minilm)  stage_serve_minilm ;;
  debug)         stage_debug ;;
  all)           stage_device; stage_compile; stage_minilm; stage_serve_minilm ;;
  *)
    echo "Usage: $0 [device|compile|minilm|serve-minilm|debug|all]" >&2
    exit 1
    ;;
esac
