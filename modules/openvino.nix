{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.mneme;

  # NPU support requires the -gpu variant; the plain image is CPU-only.
  ovmsImage = "openvino/model_server:2026.0-gpu";
in
{
  config = lib.mkIf cfg.enable {
    virtualisation.podman.enable = lib.mkDefault true;

    # OVMS in --task embeddings mode pulls the pre-converted OpenVINO IR
    # straight from HuggingFace on first start, builds the OpenAI-compatible
    # graph internally, and exposes /v1/embeddings. No host-side optimum-cli
    # export needed. The model cache lives under /models so subsequent starts
    # are instant.
    virtualisation.oci-containers.containers."mneme-ovms" = {
      image = ovmsImage;
      autoStart = true;
      ports = [ "127.0.0.1:${toString cfg.ports.openvino}:8000" ];
      volumes = [
        "${cfg.stateDir}/ovms-models:/models:rw"
      ];
      cmd = [
        "--rest_port" "8000"
        "--model_repository_path" "/models"
        "--source_model" cfg.embeddingModel
        "--task" "embeddings"
        "--pooling" "CLS"
        "--target_device" cfg.embeddingDevice
      ];
      extraOptions = [
        "--device=/dev/accel/accel0"
        # Pass host render/video GIDs numerically — podman resolves --group-add
        # names against the container's /etc/group, and OVMS's Ubuntu base has
        # no 'render' group. We pin the GIDs in default.nix.
        "--group-add=${toString config.users.groups.render.gid}"
        "--group-add=${toString config.users.groups.video.gid}"
      ];
    };
  };
}
