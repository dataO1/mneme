{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.mneme;
in
{
  imports = [
    (import ./qdrant.nix { inherit self; })
    (import ./openvino.nix { inherit self; })
    (import ./vault-mcp.nix { inherit self; })
  ];

  options.services.mneme = {
    enable = lib.mkEnableOption "mneme — local NPU semantic memory + MCP";

    user = lib.mkOption {
      type = lib.types.str;
      default = "mneme";
      description = ''
        User that runs vault-mcp and owns mneme state. Set this to your
        login user (e.g. "alice") so vault-mcp can read your home directory
        — the default synthetic "mneme" user has no access to drwx------
        home dirs. When set to "mneme" (the default) a system user is
        auto-created; any other value must already exist.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "users";
      description = ''
        Group used for mneme state ownership. Defaults to "users" so the
        run user (typically a normal login user) has access without extra
        plumbing.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/mneme";
      description = "Where Qdrant data, OVMS model cache, and vault-mcp index live.";
    };

    indexDirectories = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      example = lib.literalExpression ''
        [ "/home/alice/Documents" "/home/alice/Notes" ]
      '';
      description = ''
        Directories to recursively index. The mneme user must have read access.
      '';
    };

    obsidianVault = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Optional Obsidian vault path (treated as a markdown source with live sync).";
    };

    embeddingModel = lib.mkOption {
      type = lib.types.str;
      default = "OpenVINO/bge-small-en-v1.5-int8-ov";
      description = ''
        HuggingFace repo of the embedding model. Use a pre-converted
        OpenVINO IR (typically under the OpenVINO/ org) so OVMS can
        deploy it directly without an export step. NPU prefers static
        input shapes; INT8 IRs from the OpenVINO/ org tend to ship them.
      '';
    };

    embeddingDevice = lib.mkOption {
      type = lib.types.enum [ "CPU" "GPU" "NPU" "AUTO" ];
      default = "NPU";
      description = ''
        OpenVINO target device for embedding inference. Fall back to "CPU"
        if the model fails to load on NPU (NPU requires static shapes).
      '';
    };

    ports = {
      qdrant = lib.mkOption {
        type = lib.types.port;
        default = 6333;
        description = "Qdrant HTTP port (currently unused by vault-mcp; reserved).";
      };
      openvino = lib.mkOption {
        type = lib.types.port;
        default = 8000;
        description = "OpenVINO Model Server REST endpoint (embeddings).";
      };
      api = lib.mkOption {
        type = lib.types.port;
        default = 8765;
        description = "vault-mcp REST API port.";
      };
      mcp = lib.mkOption {
        type = lib.types.port;
        default = 8766;
        description = "vault-mcp MCP server port (separate from REST API).";
      };
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the MCP port in the firewall (default: localhost-only).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Only auto-create the synthetic system user. Real login users must
    # already exist; we just ensure they're in the render/video groups for
    # NPU access (no-op if already present).
    users.users.${cfg.user} = lib.mkMerge [
      (lib.mkIf (cfg.user == "mneme") {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.stateDir;
        createHome = true;
      })
      { extraGroups = [ "render" "video" ]; }
    ];
    users.groups.mneme = lib.mkIf (cfg.group == "mneme") { };

    # Pin render/video GIDs so the OVMS container's --group-add=<gid>
    # references stay correct. Conventional NixOS values; mkDefault means
    # any other module can override.
    users.groups.render.gid = lib.mkDefault 303;
    users.groups.video.gid = lib.mkDefault 26;

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.stateDir}/ovms-models 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.stateDir}/vault-mcp 0750 ${cfg.user} ${cfg.group} -"
    ];

    # Ensure the kernel NPU driver is available.
    boot.kernelModules = [ "intel_vpu" ];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.ports.mcp ];
  };
}
