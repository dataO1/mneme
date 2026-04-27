# mneme

Local NPU-accelerated semantic memory for your machine, exposed over MCP so any
LLM (Claude Code, Claude Desktop, local Ollama, remote agents) can query it as
persistent memory.

One NixOS flake bundles the whole stack:

- **Qdrant** — vector store
- **OpenVINO Model Server** — embedding inference on the Intel NPU
  (`Intel AI Boost`), OpenAI-compatible `/v1/embeddings`
- **vault-mcp** ([robbiemu/vault-mcp](https://github.com/robbiemu/vault-mcp))
  — indexes Obsidian / markdown / files, exposes search as MCP tools

You import the flake, point it at directories you want indexed, rebuild. Done.

## Usage

In your system flake:

```nix
{
  inputs.mneme.url = "github:dataO1/mneme";

  outputs = { self, nixpkgs, mneme, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      modules = [
        mneme.nixosModules.default
        {
          services.mneme = {
            enable = true;
            obsidianVault = "/home/me/Obsidian";
            indexDirectories = [
              "/home/me/Documents"
              "/home/me/Projects"
            ];
            # defaults shown:
            # embeddingModel = "BAAI/bge-small-en-v1.5";
            # ports.mcp      = 8765;
            # openFirewall   = false;  # localhost only
          };
        }
      ];
    };
  };
}
```

Connect Claude Code (or any MCP client) to `http://127.0.0.1:8765` (or pipe via
`mcp-proxy` for stdio).

## What you get

- `services.mneme.enable` brings up three systemd units:
  `qdrant.service`, `podman-mneme-ovms.service`, `mneme-vault-mcp.service`
- All bound to `127.0.0.1` by default.
- State under `/var/lib/mneme/` (override via `services.mneme.stateDir`).
- A dedicated `mneme` system user in groups `render` and `video` for NPU access.

## Hardware / driver requirements

- Intel Core Ultra (Meteor Lake or newer) with NPU.
  Tested target: **Core Ultra 9 275HX** (Arrow Lake-HX, NPU 3, ~13 TOPS INT8).
- Linux kernel ≥ 6.6 with `intel_vpu` driver. Hardened kernels may need the
  module enabled explicitly — `boot.kernelModules = [ "intel_vpu" ]` is set by
  the module, but verify `/dev/accel/accel0` appears after rebuild.
- Podman (enabled by default; override with `virtualisation.podman.enable`).

## Using it

Once `services.mneme.enable = true;` and rebuilt:

- **REST API**: `http://127.0.0.1:8765` — Swagger UI at `/docs`.
  Try: `/files`, `/document?path=...`, `/query?q=...` (whatever the upstream
  exposes — see `/openapi.json`).
- **MCP server**: `http://127.0.0.1:8766` — wire any MCP-capable client at
  this URL. For Claude Desktop / Crush / opencode, point their MCP config
  at the SSE/HTTP endpoint, e.g. (Claude Desktop config):

  ```json
  {
    "mcpServers": {
      "mneme": { "url": "http://127.0.0.1:8766" }
    }
  }
  ```

  Some clients only speak stdio MCP — bridge with `mcp-proxy` if so.

### How indexing happens

vault-mcp's file-watcher does the work for you: an initial recursive scan
of `paths.vault_dir` on first start, then debounced re-indexing on file
changes (default 2 s). No manual trigger. Watch progress with:

```bash
journalctl -u mneme-vault-mcp -f
```

The ChromaDB index lives at `/var/lib/mneme/vault-mcp/chroma_db/`.

### Verifying the NPU is actually being used

```bash
# OVMS should list NPU among detected devices:
journalctl -u podman-mneme-ovms | grep -i 'available devices'
# expected: "Available devices for Open VINO: CPU, NPU"

# Direct embedding latency check (NPU ≈ 5 ms, CPU ≈ 50–100 ms):
time curl -s -X POST http://127.0.0.1:8000/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"embeddings","input":"hello"}' | head -c 80
```

If only `CPU` shows up in OVMS logs, NPU passthrough isn't working — check
`/dev/accel/accel0` exists on the host and the container's `--group-add`
GIDs match `getent group render | cut -d: -f3`.

## Status / caveats

- **vault-mcp uses a runtime venv, not a pure Nix build.** Upstream pins
  `torch+cpu` from a separate index and ships `mlx-lm` as a hard dep
  (Apple-Silicon-only). Packaging that in pure Nix would mean forking and
  patching dozens of dependencies. Instead, the source tree is store-pinned
  via `fetchFromGitHub`, and the systemd service runs an `ExecStartPre`
  that builds a venv at `${stateDir}/vault-mcp/venv` on first start using
  upstream's own install path (with `mlx-lm` stripped). First start needs
  network and takes 5–10 minutes. Subsequent starts are instant. The
  bootstrap re-runs automatically when the source rev changes.
- **OVMS NPU support for embeddings is a preview feature.** If the init
  oneshot fails to export the model with a static shape, export manually
  into `${stateDir}/ovms-models/<model>/1/` and disable `mneme-ovms-init`.
- **No firewall opening by default.** Set `services.mneme.openFirewall = true`
  only if you understand what you're exposing.

## Why not just fork vault-mcp?

We don't need to. `vault-mcp` accepts `provider = "openai_endpoint"` with a
configurable `endpoint_url`, so we point it straight at the OVMS NPU endpoint.
The same trick works for `rememex`, `obsidian-notes-rag`, etc. — the embedding
backend is replaceable across the ecosystem. mneme just glues the pieces.

## License

MIT
