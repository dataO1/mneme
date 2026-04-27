{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.mneme;

  # NPU support requires the -gpu variant; the plain image is CPU-only.
  ovmsImage = "openvino/model_server:2026.0-gpu";

  # pip-installed binary wheels (numpy, torch, ...) link against the system
  # libstdc++ etc. Pure NixOS doesn't expose those, so set LD_LIBRARY_PATH.
  wheelLibPath = lib.makeLibraryPath (with pkgs; [
    stdenv.cc.cc.lib
    zlib
    glib
    openssl
  ]);

  # Init runs on the host: builds a tiny venv, runs optimum-cli to export
  # the embedding model to OpenVINO IR, then writes the OVMS config. Mirrors
  # the vault-mcp bootstrap pattern (network at first start, idempotent).
  initScript = pkgs.writeShellApplication {
    name = "mneme-ovms-init";
    runtimeInputs = [ pkgs.python311 pkgs.coreutils ];
    text = ''
      set -euo pipefail
      MODELS_DIR="${cfg.stateDir}/ovms-models"
      MODEL_NAME="${cfg.embeddingModel}"
      SAFE_NAME="$(echo "$MODEL_NAME" | tr '/' '_')"
      TARGET="$MODELS_DIR/$SAFE_NAME"
      VENV="$MODELS_DIR/.export-venv"

      if [ ! -d "$TARGET/1" ]; then
        echo "[mneme-ovms-init] Exporting $MODEL_NAME via optimum-intel..."
        if [ ! -x "$VENV/bin/optimum-cli" ]; then
          ${pkgs.python311}/bin/python -m venv "$VENV"
          "$VENV/bin/pip" install --upgrade pip wheel
          # Pre-install CPU-only torch so optimum's transitive deps don't
          # pull in 3+ GB of CUDA wheels.
          "$VENV/bin/pip" install --index-url https://download.pytorch.org/whl/cpu torch
          "$VENV/bin/pip" install 'optimum[openvino]>=1.20'
        fi
        mkdir -p "$TARGET/1"
        "$VENV/bin/optimum-cli" export openvino \
          --model "$MODEL_NAME" \
          --task feature-extraction \
          --weight-format int8 \
          "$TARGET/1"
      fi

      cat > "$MODELS_DIR/config.json" <<EOF
      {
        "model_config_list": [
          {
            "config": {
              "name": "embeddings",
              "base_path": "/models/$SAFE_NAME",
              "target_device": "NPU"
            }
          }
        ]
      }
      EOF
      echo "[mneme-ovms-init] OVMS config ready at $MODELS_DIR/config.json"
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    virtualisation.podman.enable = lib.mkDefault true;

    systemd.services."mneme-ovms-init" = {
      description = "mneme: prepare OVMS embedding model";
      wantedBy = [ "podman-mneme-ovms.service" ];
      before = [ "podman-mneme-ovms.service" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment.LD_LIBRARY_PATH = wheelLibPath;
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${initScript}/bin/mneme-ovms-init";
        RemainAfterExit = true;
        TimeoutStartSec = "20min";
      };
    };

    virtualisation.oci-containers.containers."mneme-ovms" = {
      image = ovmsImage;
      autoStart = true;
      ports = [ "127.0.0.1:${toString cfg.ports.openvino}:8000" ];
      volumes = [
        "${cfg.stateDir}/ovms-models:/models:ro"
      ];
      cmd = [
        "--config_path" "/models/config.json"
        "--rest_port" "8000"
      ];
      extraOptions = [
        # NPU device passthrough.
        "--device=/dev/accel/accel0"
        # Grant the in-container user the host's render group GID so it can
        # open /dev/accel/accel0. Names are resolved against the host's
        # /etc/group by podman.
        "--group-add=render"
        "--group-add=video"
      ];
    };
  };
}
