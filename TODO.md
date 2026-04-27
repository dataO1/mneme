# mneme — open work

## Multi-instance support (separate DBs, shared embedding endpoint)

vault-mcp uses `chromadb.PersistentClient` (SQLite under the hood). Multiple
instances cannot safely share one DB directory — SQLite locks the whole file
on writes and each instance runs its own file-watcher, so contention and
corruption are likely.

**Goal:** add `services.mneme.instances = { name = { vaultDir; ports.api;
ports.mcp; type ? "Standard"; }; ... };` so multiple `vault-mcp` units run
side by side, each with its own ChromaDB directory under
`${stateDir}/vault-mcp-<name>/chroma_db`. They share only the OVMS
embedding endpoint.

Sketch:

- Drop the singular `vaultDir` / `obsidianVault` / `indexDirectories` options
  in favour of the `instances` attrset.
- Or keep them as syntactic sugar that constructs a single-entry `instances`
  attrset under the hood.
- Each entry generates its own systemd unit, app.toml directory, ChromaDB
  path, and ports. Health-check that ports don't collide.
- MCP clients connect to whichever instance is relevant (`mneme-notes`,
  `mneme-docs`, `mneme-code`, ...).

**Why this matters:** vault-mcp can only point at one directory per process.
Without this, users have to choose between e.g. Notes and Documents.

## Other

- Cleaner exclude story for the single-source case (vault-mcp has no glob
  excludes; pointing at `~` pulls in `.cache`, `.git`, `node_modules`).
  Options: build a symlink farm under stateDir from a user-curated include
  list, or fork upstream to add an exclude list. Symlink farm is non-invasive
  and easier to revert.
- Drop or hide Qdrant from the default config — vault-mcp doesn't use it.
  Keep behind an `services.mneme.qdrant.enable` toggle for future indexers.
- Validate NPU is actually being used (not falling back to CPU). After
  rebuild, `journalctl -u podman-mneme-ovms` should report `Available devices
  for Open VINO: CPU, NPU` and inference latency on `/v1/embeddings` should
  be ~5 ms, not ~100 ms.
- Pre-export the embedding model via a fixed-output Nix derivation instead
  of the runtime `optimum-cli` venv. Removes network dep at first start.
