{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.mneme;

  vaultMcpSrc = pkgs.callPackage ../pkgs/vault-mcp.nix { };

  python = pkgs.python311;

  # pip-installed binary wheels (numpy, torch, ...) link against the system
  # libstdc++ etc. Pure NixOS doesn't expose those, so set LD_LIBRARY_PATH.
  wheelLibPath = lib.makeLibraryPath (with pkgs; [
    stdenv.cc.cc.lib
    zlib
    glib
    openssl
  ]);

  # vault-mcp only supports a single source dir (paths.vault_dir) and a
  # hardcoded ChromaDB backend. Strategy:
  #   - obsidianVault set → use it directly with type="Obsidian" (so the
  #     llama-index Obsidian reader handles wikilinks/frontmatter). User
  #     accepts whatever's in the vault tree as-is.
  #   - else → build a symlink farm under stateDir from indexDirectories,
  #     pruning excludePatterns and respecting .gitignore for git repos.
  #     Point vault_dir at the farm. Multiple input dirs become subdirs of
  #     the farm.
  farmDir = "${cfg.stateDir}/vault-mcp/source";
  useFarm = cfg.obsidianVault == null;

  vaultDir =
    if cfg.obsidianVault != null then toString cfg.obsidianVault
    else if cfg.indexDirectories != [ ] then farmDir
    else throw "services.mneme: set obsidianVault or at least one indexDirectories entry";

  vaultType = if cfg.obsidianVault != null then "Obsidian" else "Standard";

  # Symlink farm builder: walks each source dir, prunes excludePatterns,
  # uses `git ls-files` inside git repos so .gitignore is honoured. Output
  # is a tree of symlinks under $FARM/<basename>/... pointing at originals.
  buildSourceScript = pkgs.writeShellApplication {
    name = "mneme-build-source";
    runtimeInputs = [ pkgs.coreutils pkgs.fd pkgs.git ];
    text = ''
      set -euo pipefail
      FARM="$1"
      shift

      EXCLUDES=( ${lib.escapeShellArgs cfg.excludePatterns} )

      # fd takes one --exclude per pattern.
      FD_EXCLUDES=()
      for p in "''${EXCLUDES[@]}"; do
        FD_EXCLUDES+=( --exclude "$p" )
      done

      progress() {
        local n="$1" src="$2"
        if [ $((n % 500)) -eq 0 ]; then
          echo "[mneme-build-source]   ... $n files from $src"
        fi
      }

      rm -rf "$FARM"
      mkdir -p "$FARM"

      total=0
      for src in "$@"; do
        [ -d "$src" ] || { echo "[mneme-build-source] skipping missing $src"; continue; }
        name="$(basename "$src")"
        dest="$FARM/$name"
        mkdir -p "$dest"
        n=0

        if [ -d "$src/.git" ]; then
          echo "[mneme-build-source] $src is a git repo — using git ls-files"
          while IFS= read -r -d "" f; do
            target="$dest/$f"
            mkdir -p "$(dirname "$target")"
            ln -sfn "$src/$f" "$target"
            n=$((n + 1))
            progress "$n" "$src"
          done < <(cd "$src" && git ls-files -z)
        else
          echo "[mneme-build-source] $src — fd walk with excludes"
          # --hidden so dotfiles are visible; --no-ignore so we ignore any
          # ambient .gitignore (we control filtering via EXCLUDES). --type f
          # gets only regular files. -0 = NUL-separated.
          while IFS= read -r -d "" f; do
            rel="''${f#"$src"/}"
            target="$dest/$rel"
            mkdir -p "$(dirname "$target")"
            ln -sfn "$f" "$target"
            n=$((n + 1))
            progress "$n" "$src"
          done < <(fd --hidden --no-ignore --type f -0 "''${FD_EXCLUDES[@]}" . "$src")
        fi
        echo "[mneme-build-source]   $n files linked from $src"
        total=$((total + n))
      done

      echo "[mneme-build-source] total $total files in $FARM"
    '';
  };

  # vault-mcp's loader does `open(os.path.join(config_path, "app.toml"))`,
  # so --config must point at a *directory* containing app.toml.
  appConfigDir = pkgs.writeTextDir "app.toml" ''
    [paths]
    vault_dir = "${vaultDir}"
    database_dir = "${cfg.stateDir}/vault-mcp/chroma_db"
    data_dir = "${cfg.stateDir}/vault-mcp/data"
    type = "${vaultType}"

    [server]
    host = "127.0.0.1"
    api_port = ${toString cfg.ports.api}
    mcp_port = ${toString cfg.ports.mcp}

    [embedding_model]
    provider = "openai_endpoint"
    model_name = "embeddings"
    # OVMS in --task embeddings mode serves OpenAI-compatible embeddings
    # under /v3, not /v1. Verified by direct curl.
    endpoint_url = "http://127.0.0.1:${toString cfg.ports.openvino}/v3"
    api_key = "unused"

    [retrieval]
    # "static" avoids requiring a generation_model. Switch to "agentic" and
    # add a [generation_model] block to enable LLM-mediated retrieval.
    mode = "static"

    [watcher]
    enabled = true
    debounce_seconds = 2
  '';

  # Bootstrap script: idempotently builds a venv at $VENV using upstream's
  # install_deps.sh logic, then installs the project in editable mode.
  # Runs as ExecStartPre. Needs network on first invocation. The stamp
  # combines the source rev with the bootstrap derivation hash, so any
  # change to the bootstrap script auto-invalidates the venv.
  bootstrap = pkgs.writeShellApplication {
    name = "mneme-vault-mcp-bootstrap";
    runtimeInputs = [ python pkgs.gnused pkgs.coreutils ];
    text = ''
      set -euo pipefail
      VENV="$1"
      SRC_RO="${vaultMcpSrc}/share/vault-mcp"
      WORK="${cfg.stateDir}/vault-mcp/build"
      STAMP="${vaultMcpSrc.version}+bootstrap=$(basename "$0")"

      if [ -x "$VENV/bin/vault-mcp" ] && [ -f "$VENV/.mneme-rev" ] \
         && [ "$(cat "$VENV/.mneme-rev")" = "$STAMP" ]; then
        exit 0
      fi

      echo "[mneme] First-time setup of vault-mcp venv at $VENV (5–10 min)..."
      rm -rf "$VENV" "$WORK"
      mkdir -p "$WORK"
      cp -rT "$SRC_RO" "$WORK"
      chmod -R u+w "$WORK"

      # mlx-lm is Apple-Silicon-only; remove it before installing.
      sed -i '/^[[:space:]]*"mlx-lm/d' "$WORK/pyproject.toml"

      # Upstream's pyproject only packages `components` and `shared` into the
      # wheel, but the entrypoint script does `from vault_mcp.main import run`.
      # Add the missing top-level packages so the install is actually usable.
      sed -i \
        's|^packages = \["components", "shared"\]|packages = ["components", "shared", "vault_mcp", "plugins"]|' \
        "$WORK/pyproject.toml"

      # Parallelise initial file loading. SimpleDirectoryReader.load_data()
      # is single-threaded by default; pass num_workers so all cores get
      # used during the initial scan of the symlink farm.
      sed -i \
        's|reader\.load_data()|reader.load_data(num_workers=${toString cfg.indexWorkers})|g' \
        "$WORK/components/document_processing/document_loader.py"

      # Constrain the input_files branch to text-y extensions only. Without
      # required_exts, llama-index inspects any extension and demands
      # whisper/etc. for audio/video. We also pre-filter audio/video at the
      # farm level, but this defends against any leaks.
      sed -i \
        's|SimpleDirectoryReader(input_files=files_to_process)|SimpleDirectoryReader(input_files=files_to_process, required_exts=${
          builtins.toJSON cfg.requiredExts
        })|g' \
        "$WORK/components/document_processing/document_loader.py"

      ${python}/bin/python -m venv "$VENV"
      "$VENV/bin/pip" install --upgrade pip wheel

      # CPU-only PyTorch (matches upstream install_deps.sh).
      "$VENV/bin/pip" install \
        torch==2.3.0+cpu torchvision==0.18.0+cpu torchaudio==2.3.0+cpu \
        --index-url https://download.pytorch.org/whl/cpu

      # Project + remaining deps.
      "$VENV/bin/pip" install "$WORK"

      echo "$STAMP" > "$VENV/.mneme-rev"
      echo "[mneme] vault-mcp venv ready."
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    # Farm build runs decoupled from nixos-rebuild and from vault-mcp itself:
    # a timer fires shortly after boot and then every 30 min. vault-mcp's
    # file-watcher picks up the symlinks as they appear. First-boot effect:
    # the index is empty for ~30 s, then fills in. Avoids the multi-minute
    # ExecStartPre that was making `nixos-rebuild switch` look hung.
    systemd.services."mneme-source-build" = lib.mkIf useFarm {
      description = "mneme: build symlink farm for vault-mcp";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${buildSourceScript}/bin/mneme-build-source ${farmDir} ${
          lib.escapeShellArgs (map toString cfg.indexDirectories)
        }";
        TimeoutStartSec = "30min";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers."mneme-source-build" = lib.mkIf useFarm {
      description = "Periodic mneme symlink farm rebuild";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Fire as soon as the timer loads (after switch-to-configuration
        # has returned, so nixos-rebuild doesn't block on the walk). Then
        # again every 30 min. Nice=10 + IOSchedulingClass=idle keeps the
        # build out of the way of foreground work.
        OnActiveSec = "0";
        OnUnitActiveSec = "30min";
        Persistent = true;
      };
    };

    systemd.services."mneme-vault-mcp" = {
      description = "mneme: vault-mcp MCP server";
      wantedBy = [ "multi-user.target" ];
      # vault-mcp uses ChromaDB locally (file-backed under chroma_db).
      # It does not talk to Qdrant; ordering only requires OVMS + network.
      after = [ "network-online.target" "podman-mneme-ovms.service" "mneme-ovms-init.service" ];
      wants = [ "network-online.target" ];

      environment.LD_LIBRARY_PATH = wheelLibPath;
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        ExecStartPre = "${bootstrap}/bin/mneme-vault-mcp-bootstrap ${cfg.stateDir}/vault-mcp/venv";
        ExecStart = "${cfg.stateDir}/vault-mcp/venv/bin/vault-mcp --config ${appConfigDir}";
        Restart = "on-failure";
        RestartSec = 5;
        # First-run venv build can take a while.
        TimeoutStartSec = "20min";
        # Hardening (relaxed: bootstrap needs to write under stateDir and reach PyPI).
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.stateDir ];
        ProtectHome = lib.mkDefault "read-only";
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
  };
}
