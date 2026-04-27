{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.mneme;

  # OpenVINO Model Server with NPU support.
  # Image tag pinned to a known release; bump when validating against newer OVMS.
  ovmsImage = "openvino/model_server:2026.0";

  # Static script that, on first run, exports the configured BGE model to OpenVINO IR
  # with a static input shape (NPU requirement) and writes an OVMS config.
  modelInitScript = pkgs.writeShellApplication {
    name = "mneme-ovms-init";
    runtimeInputs = with pkgs; [ podman python3 ];
    text = ''
      set -euo pipefail
      MODELS_DIR="${cfg.stateDir}/ovms-models"
      MODEL_NAME="${cfg.embeddingModel}"
      # Sanitize for filesystem use
      SAFE_NAME="$(echo "$MODEL_NAME" | tr '/' '_')"
      TARGET="$MODELS_DIR/$SAFE_NAME"

      if [ ! -d "$TARGET/1" ]; then
        echo "[mneme] Exporting $MODEL_NAME to OpenVINO IR (NPU static shape) ..."
        mkdir -p "$TARGET/1"
        # Use the OVMS image's bundled optimum-cli to export with a fixed sequence length.
        ${pkgs.podman}/bin/podman run --rm \
          -v "$TARGET/1":/out \
          --entrypoint /bin/bash \
          ${ovmsImage} \
          -lc "pip install --quiet 'optimum[openvino]' && \
               optimum-cli export openvino \
                 --model '$MODEL_NAME' \
                 --task feature-extraction \
                 --weight-format int8 \
                 /out"
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
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    virtualisation.podman.enable = lib.mkDefault true;

    systemd.services."mneme-ovms-init" = {
      description = "mneme: prepare OVMS embedding model";
      wantedBy = [ "mneme-ovms.service" ];
      before = [ "mneme-ovms.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${modelInitScript}/bin/mneme-ovms-init";
        RemainAfterExit = true;
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
        # NPU device passthrough (intel_vpu exposes /dev/accel/accel0).
        "--device=/dev/accel"
        # Render group access for the NPU char device.
        "--group-add=keep-groups"
      ];
    };
  };
}
