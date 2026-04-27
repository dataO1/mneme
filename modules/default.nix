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
      default = "OpenVINO/bge-base-en-v1.5-int8-ov";
      description = ''
        HuggingFace repo of the embedding model. Use a pre-converted
        OpenVINO IR (under the OpenVINO/ org) so OVMS can deploy it
        directly without an export step. The default is the model the
        OVMS docs use as a canonical example; bge-small is *not* in the
        OpenVINO org, despite what the BAAI naming suggests.
        NPU prefers static input shapes; INT8 IRs ship them.
      '';
    };

    excludePatterns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        # Dev / cache dirs
        ".git" ".direnv" ".envrc"
        ".cache" ".local" ".npm" ".pnpm-store" ".cargo" ".rustup"
        ".gradle" ".m2" ".ivy2" ".gem" ".thumbnails"
        "node_modules" "target" "build" "dist" "out"
        "__pycache__" ".venv" "venv" ".tox"
        ".next" ".nuxt" ".turbo" ".parcel-cache"
        "result" "result-*"
        ".DS_Store" ".trash" "Trash"
        # Audio / video — vault-mcp's loader pulls in whisper for these and
        # crashes if it isn't installed; we don't want them indexed anyway.
        "*.mp3" "*.m4a" "*.flac" "*.ogg" "*.opus" "*.wav" "*.aac" "*.wma"
        "*.mp4" "*.mkv" "*.mov" "*.avi" "*.webm" "*.wmv" "*.m4v" "*.flv"
        # Big binary clutter that we'd never want as text either
        "*.iso" "*.img" "*.dmg" "*.zip" "*.tar" "*.gz" "*.bz2" "*.xz"
        "*.7z" "*.rar"
      ];
      description = ''
        Names/globs to prune when building the symlink farm vault-mcp
        indexes (passed to `fd --exclude`). Source dirs that are git repos
        use `git ls-files` instead, so .gitignore is honoured automatically
        and this list only kicks in for non-repo trees.
      '';
    };

    requiredExts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ".md" ".txt" ".rst" ".org" ".pdf" ".markdown" ];
      description = ''
        File extensions vault-mcp's SimpleDirectoryReader is allowed to
        load. The bootstrap patches the bare `SimpleDirectoryReader(
        input_files=...)` call site to pass these as `required_exts`,
        which upstream forgot to do — without that, llama-index inspects
        any extension it doesn't recognise (audio, video, ...) and demands
        extra dependencies (e.g. whisper).
      '';
    };

    indexWorkers = lib.mkOption {
      type = lib.types.int;
      default = 16;
      description = ''
        Worker count for parallel file loading inside vault-mcp's
        SimpleDirectoryReader. Upstream calls load_data() with no kwargs,
        making the initial scan single-threaded. The bootstrap patches
        the call site to pass num_workers=this. Set to 1 to disable.
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
      # Pre-create the farm dir so vault-mcp doesn't choke on a missing
      # vault_dir before the source-build timer fires (~30 s after boot).
      "d ${cfg.stateDir}/vault-mcp/source 0750 ${cfg.user} ${cfg.group} -"
      # Recursive chown: when cfg.user changes (e.g. mneme -> data01) the
      # existing tree must be re-owned, otherwise ChromaDB hits 'attempt to
      # write a readonly database'.
      "Z ${cfg.stateDir}/vault-mcp 0750 ${cfg.user} ${cfg.group} -"
    ];

    # Ensure the kernel NPU driver is available.
    boot.kernelModules = [ "intel_vpu" ];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.ports.mcp ];
  };
}
