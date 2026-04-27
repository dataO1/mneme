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

  echo "--- generated graph.pbtxt (path lines OVMS will try to resolve):"
  sudo grep -E 'graph_path|target_device|model_path|servable_name' \
    "$TEST_MODELS_DIR/sentence-transformers/all-MiniLM-L6-v2/graph.pbtxt" 2>/dev/null \
    | head -10
  echo
  echo "--- on-disk model files (must match what graph.pbtxt references):"
  sudo find "$TEST_MODELS_DIR/sentence-transformers/all-MiniLM-L6-v2" -maxdepth 3 \
    \( -name '*.xml' -o -name '*.bin' -o -name 'graph.pbtxt' \) 2>/dev/null
  echo
  echo "--- OVMS startup (full last 80 lines, no grep):"

  # `timeout` SIGKILLs after 25 s; podman run inherits and the container exits.
  timeout 25 sudo podman run --rm -i \
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
    --log_level DEBUG 2>&1 | tail -80
  echo
  echo "(timeout reached or container exited)"
}

stage_static_bge() {
  echo "=== [4] Static-shape bge-base compile test on NPU (bypasses OVMS) ==="
  echo "Exports BAAI/bge-base-en-v1.5 to OpenVINO IR, reshapes inputs to"
  echo "[1, 512] (static), then calls core.compile_model(model, 'NPU')."
  echo "If this works, the path forward is 'pre-export with static shapes'."
  echo "If it fails, NPU 3 + bge-base is fundamentally incompatible."
  echo

  podman_npu \
    --entrypoint /bin/bash \
    -e HF_HOME=/tmp/hf-cache \
    "$OV_DEV_IMAGE" \
    -lc '
set -e
echo "Installing optimum[openvino] (one-shot, in-container)..."
pip install --quiet --no-warn-script-location "optimum[openvino]>=1.20" "openvino-tokenizers"

python3 - <<PY
import subprocess, sys
import numpy as np
import openvino as ov

print("Exporting BAAI/bge-base-en-v1.5 → /tmp/static-bge (INT8) ...")
subprocess.check_call([
    "optimum-cli", "export", "openvino",
    "--model", "BAAI/bge-base-en-v1.5",
    "--task", "feature-extraction",
    "--weight-format", "int8",
    "--library", "transformers",
    "/tmp/static-bge",
])

core = ov.Core()
model = core.read_model("/tmp/static-bge/openvino_model.xml")
print("\nDynamic input shapes:", [str(p.partial_shape) for p in model.inputs])

print("Reshaping all inputs to [1, 512] ...")
model.reshape({p.get_any_name(): [1, 512] for p in model.inputs})
print("Static input shapes:", [str(p.partial_shape) for p in model.inputs])

print("\nCompiling on NPU ...")
try:
    compiled = core.compile_model(model, "NPU")
    print("✓ compiled OK on NPU")
except Exception as e:
    print("✗ NPU compile failed:")
    print(e)
    sys.exit(2)

print("\nInference smoke test ...")
inputs = {
    "input_ids":      np.zeros((1, 512), dtype=np.int64),
    "attention_mask": np.ones( (1, 512), dtype=np.int64),
    "token_type_ids": np.zeros((1, 512), dtype=np.int64),
}
inputs = {n: v for n, v in inputs.items() if any(p.get_any_name() == n for p in model.inputs)}
result = compiled(inputs)
shapes = [list(v.shape) for v in result.values()]
print("✓ inference output shape(s):", shapes)
PY'
  echo
}

stage_static_long() {
  echo "=== [5] Static-shape long-context model compile test on NPU ==="
  echo "Default model: Snowflake/snowflake-arctic-embed-m-long (137M, BERT,"
  echo "2048 ctx — 4× bge-base). Override with MODEL env var."
  echo "Tries seq_len 2048 → 512, prints the largest that compiles."
  echo "If any work, that model ships in the production pull;"
  echo "if none, fall back to bge-base @ [1, 512] (NPU-3)."
  echo
  echo "Note: nomic-embed-text-v1.5 was first choice but uses a custom"
  echo "      nomic_bert architecture that optimum-intel doesn't natively"
  echo "      support. Arctic-m-long is the next-best 'standard BERT,"
  echo "      long context' option."
  echo

  podman_npu \
    --entrypoint /bin/bash \
    -e HF_HOME=/tmp/hf-cache \
    -e MODEL="${MODEL:-Snowflake/snowflake-arctic-embed-m-long}" \
    "$OV_DEV_IMAGE" \
    -lc '
set -e
echo "Installing optimum[openvino] (one-shot, in-container)..."
pip install --quiet --no-warn-script-location \
  "optimum[openvino]>=1.20" "openvino-tokenizers"

python3 - <<PY
import os, subprocess, sys
import numpy as np
import openvino as ov

MODEL = os.environ["MODEL"]
EXPORT_DIR = "/tmp/static-long"

print(f"Exporting {MODEL} → {EXPORT_DIR} (INT8) ...")
subprocess.check_call([
    "optimum-cli", "export", "openvino",
    "--model", MODEL,
    "--task", "feature-extraction",
    "--weight-format", "int8",
    "--library", "transformers",
    "--trust-remote-code",
    EXPORT_DIR,
])

core = ov.Core()
fresh = lambda: core.read_model(f"{EXPORT_DIR}/openvino_model.xml")
print()
print("Dynamic input shapes:", [str(p.partial_shape) for p in fresh().inputs])

results = []
# Largest first; arctic-m-long maxes at 2048. If MODEL is overridden to
# something with longer context (e.g. an 8192 model that does export),
# bump the list manually.
for seq_len in (2048, 512):
    print(f"\n--- seq_len = {seq_len}")
    model = fresh()
    try:
        model.reshape({p.get_any_name(): [1, seq_len] for p in model.inputs})
    except Exception as e:
        print(f"  reshape failed: {e}")
        results.append((seq_len, "reshape-failed", str(e)))
        continue

    try:
        compiled = core.compile_model(model, "NPU")
        print(f"  ✓ compiled OK at seq_len={seq_len}")
    except Exception as e:
        print(f"  ✗ NPU compile failed at seq_len={seq_len}")
        msg = str(e)
        # Print first 400 chars so we see compiler error category, not novel
        print("  ", msg[:400].replace("\n", "\n  "))
        results.append((seq_len, "compile-failed", msg))
        continue

    try:
        inputs = {}
        for p in model.inputs:
            n = p.get_any_name()
            shape = [1, seq_len]
            dtype = np.int64 if "ids" in n or "mask" in n else np.float32
            inputs[n] = np.zeros(shape, dtype=dtype)
        out = compiled(inputs)
        shapes = [list(v.shape) for v in out.values()]
        print(f"  ✓ inference output shape(s): {shapes}")
        results.append((seq_len, "ok", shapes))
    except Exception as e:
        print(f"  ✗ inference failed: {e}")
        results.append((seq_len, "inference-failed", str(e)))

print("\n========== SUMMARY ==========")
for seq_len, status, _ in results:
    print(f"  seq_len={seq_len}: {status}")

oks = [r for r in results if r[1] == "ok"]
if oks:
    best = max(oks, key=lambda r: r[0])
    print(f"\nVERDICT: {MODEL} compiles + runs on NPU at seq_len={best[0]}.")
    print("→ Proceed with NPU-2: ship this model + seq_len in the production pull.")
else:
    print(f"\nVERDICT: {MODEL} does not compile on NPU at any tested seq_len.")
    print("→ Fall back to NPU-3: keep bge-base @ [1, 512].")
    sys.exit(2)
PY'
  echo
}

stage_static_search() {
  echo "=== [6] Multi-model NPU search ==="
  echo "Probes a curated candidate list. For each: export to OpenVINO IR,"
  echo "reshape inputs to a static max-context, compile on NPU, smoke-test."
  echo "Prints a summary table at the end showing which models survived."
  echo
  echo "Candidates (long-context first, then bigger BERTs as quality fallback):"
  echo "  1. nomic-ai/modernbert-embed-base       (149M, 8192 ctx, ModernBERT)"
  echo "  2. answerdotai/ModernBERT-base          (149M, 8192 ctx, ModernBERT)"
  echo "  3. intfloat/e5-base-v2                  (110M,  512 ctx, BERT)"
  echo "  4. BAAI/bge-large-en-v1.5               (335M,  512 ctx, BERT)"
  echo "  5. mixedbread-ai/mxbai-embed-large-v1   (335M,  512 ctx, BERT)"
  echo "  6. intfloat/multilingual-e5-base        (278M,  512 ctx, XLM-RoBERTa)"
  echo

  podman_npu \
    --entrypoint /bin/bash \
    -e HF_HOME=/tmp/hf-cache \
    "$OV_DEV_IMAGE" \
    -lc '
set -e
echo "Installing optimum[openvino] (one-shot, in-container)..."
pip install --quiet --no-warn-script-location \
  "optimum[openvino]>=1.20" "openvino-tokenizers"

python3 - <<PY
import os, subprocess, traceback
import numpy as np
import openvino as ov

# (model, target_seq_len). target_seq_len = the largest static shape we
# bother trying for that model. Capped at 2048 to keep NPU memory in budget.
CANDIDATES = [
    ("nomic-ai/modernbert-embed-base",       2048),
    ("answerdotai/ModernBERT-base",          2048),
    ("intfloat/e5-base-v2",                   512),
    ("BAAI/bge-large-en-v1.5",                512),
    ("mixedbread-ai/mxbai-embed-large-v1",    512),
    ("intfloat/multilingual-e5-base",         512),
]

results = []
core = ov.Core()

for model_id, target_seq in CANDIDATES:
    print(f"\n========== {model_id} (target_seq={target_seq}) ==========")
    safe = model_id.replace("/", "_")
    out_dir = f"/tmp/search-{safe}"
    try:
        subprocess.check_call([
            "optimum-cli", "export", "openvino",
            "--model", model_id,
            "--task", "feature-extraction",
            "--weight-format", "int8",
            "--library", "transformers",
            "--trust-remote-code",
            out_dir,
        ])
    except Exception as e:
        print(f"  ✗ export failed: {type(e).__name__}: {str(e)[:200]}")
        results.append((model_id, target_seq, "export-failed", None))
        continue

    # Try target_seq, fall back to 512 if that fails to compile.
    compiled_at = None
    last_err = None
    for seq_len in (target_seq, 512) if target_seq != 512 else (512,):
        try:
            model = core.read_model(f"{out_dir}/openvino_model.xml")
            model.reshape({p.get_any_name(): [1, seq_len] for p in model.inputs})
            compiled = core.compile_model(model, "NPU")
            # Smoke inference.
            inputs = {}
            for p in model.inputs:
                n = p.get_any_name()
                dtype = np.int64 if ("ids" in n or "mask" in n) else np.float32
                inputs[n] = np.zeros([1, seq_len], dtype=dtype)
            out = compiled(inputs)
            shapes = [list(v.shape) for v in out.values()]
            print(f"  ✓ seq_len={seq_len}: compiled + inferred OK; shapes={shapes}")
            compiled_at = seq_len
            break
        except Exception as e:
            print(f"  ✗ seq_len={seq_len}: {type(e).__name__}: {str(e)[:240]}")
            last_err = str(e)[:240]

    if compiled_at:
        results.append((model_id, compiled_at, "ok", None))
    else:
        results.append((model_id, target_seq, "compile-failed", last_err))

print("\n" + "=" * 78)
print("SUMMARY")
print("=" * 78)
print(f"{'model':<45} {'seq':>6}  {'status':<18}")
print("-" * 78)
for model_id, seq, status, _ in results:
    print(f"{model_id:<45} {seq:>6}  {status:<18}")
print()

oks = [r for r in results if r[2] == "ok"]
if oks:
    print("WORKING ON NPU:")
    for r in oks:
        print(f"  {r[0]} @ seq_len={r[1]}")
    print()
    print("Pick: largest context that compiled, then by quality.")
    print("If a ModernBERT variant survived, that is the winner (long ctx +")
    print("modern training). Otherwise pick the bigger BERT for quality")
    print("(bge-large > mxbai-large > e5-base-v2 > bge-base).")
else:
    print("Nothing else compiled. Stick with bge-base @ [1, 512] (NPU-3).")
PY'
  echo
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
  static-bge)    stage_static_bge ;;
  static-long)   stage_static_long ;;
  static-search) stage_static_search ;;
  debug)         stage_debug ;;
  all)           stage_device; stage_compile; stage_minilm; stage_serve_minilm; stage_static_bge; stage_static_long ;;
  *)
    echo "Usage: $0 [device|compile|minilm|serve-minilm|static-bge|static-long|static-search|debug|all]" >&2
    echo "  static-long:   override model with MODEL=<hf/repo> env var" >&2
    echo "  static-search: probe a curated candidate list, print verdict table" >&2
    exit 1
    ;;
esac
