{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.mneme;

  # NPU support requires the -gpu variant; the plain image is CPU-only.
  ovmsImage = "openvino/model_server:2026.0-gpu";

  # OVMS deploys embedding models in a two-phase pattern:
  #   1. `ovms --pull ... --task embeddings`  → downloads the IR + writes
  #      an auto-generated /models/config.json with the OpenAI graph.
  #   2. `ovms --config_path /models/config.json --rest_port 8000` → serves.
  # We use a oneshot pre-start to do (1), then the persistent oci-containers
  # unit for (2). Both run as root in the container so they can read/write
  # the bind-mounted /models dir owned by cfg.user on the host.
  pullScript = pkgs.writeShellApplication {
    name = "mneme-ovms-pull";
    runtimeInputs = [ pkgs.podman ];
    text = ''
      set -euo pipefail
      MODELS_DIR="${cfg.stateDir}/ovms-models"

      if [ -f "$MODELS_DIR/config.json" ]; then
        echo "[mneme-ovms-pull] $MODELS_DIR/config.json present, skipping pull."
        exit 0
      fi

      echo "[mneme-ovms-pull] Pulling ${cfg.embeddingModel} (~50 MB, ~30 s)..."
      ${pkgs.podman}/bin/podman run --rm \
        --user=0:0 \
        -v "$MODELS_DIR":/models:rw \
        ${ovmsImage} \
        --pull \
        --model_repository_path /models \
        --source_model ${cfg.embeddingModel} \
        --task embeddings \
        --pooling CLS \
        --target_device ${cfg.embeddingDevice}

      # OVMS --pull writes <model>/graph.pbtxt but does NOT write the
      # top-level config.json. Hand-write it.
      #
      # Important quirk: OVMS resolves model files as
      #   <model_repository_path>/<mediapipe.name>/<relative-path-from-pbtxt>
      # regardless of the explicit graph_path. So with name="embeddings",
      # OVMS expects files under /models/embeddings/. Symlink the pulled
      # model dir there so the resolution lines up.
      ln -sfnT "${cfg.embeddingModel}" "$MODELS_DIR/embeddings"

      cat > "$MODELS_DIR/config.json" <<'EOF'
      {
        "model_config_list": [],
        "mediapipe_config_list": [
          {
            "name": "embeddings",
            "graph_path": "/models/embeddings/graph.pbtxt"
          }
        ]
      }
      EOF

      echo "[mneme-ovms-pull] Done."
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    virtualisation.podman.enable = lib.mkDefault true;

    systemd.services."mneme-ovms-pull" = {
      description = "mneme: pull OVMS embedding model + generate config";
      wantedBy = [ "podman-mneme-ovms.service" ];
      before = [ "podman-mneme-ovms.service" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        # Root: needs to talk to the rootful podman socket and bind-mount
        # the models dir RW.
        User = "root";
        ExecStart = "${pullScript}/bin/mneme-ovms-pull";
        RemainAfterExit = true;
        TimeoutStartSec = "10min";
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
        "--rest_port" "8000"
        "--config_path" "/models/config.json"
      ];
      extraOptions = [
        # Run as root inside the container; the OVMS image's default 'ovms'
        # user (uid 5000) can't read our 0750 host dir.
        "--user=0:0"
        "--device=/dev/accel/accel0"
        "--group-add=${toString config.users.groups.render.gid}"
        "--group-add=${toString config.users.groups.video.gid}"
      ];
    };
  };
}
