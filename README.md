# PUSH - Git-Based Binary Cache

PUSH is the binary cache component of [buildbuild](../README.md). It stores uncompressed Nix Archive (NAR) files in a standard Git repository, leveraging Git's native delta compression for efficient deduplication across build variants and versions. PUSH implements the Nix substituter protocol, allowing Nix to fetch cached build artifacts directly from a GitHub-hosted repository.

## Table of Contents

- [Setting Up the Cache Repository](#setting-up-the-cache-repository)
- [Configuring as a Nix Substituter](#configuring-as-a-nix-substituter)
  - [Private Repositories](#private-repositories)
- [Why Uncompressed NARs](#why-uncompressed-nars)
- [Storage Layout](#storage-layout)
- [upload.sh Usage](#uploadsh-usage)
- [Environment Variables](#environment-variables)
- [Content-Addressed Logging](#content-addressed-logging)
- [narinfo Format Reference](#narinfo-format-reference)
- [manifest.json Format Reference](#manifestjson-format-reference)
- [File Size Limits](#file-size-limits)
- [Dependencies](#dependencies)
- [License](#license)

## Setting Up the Cache Repository

### 1. Create a New GitHub Repository

Create a new GitHub repository to serve as the cache. It can be public (for open-source projects) or private (requires a token for Nix to fetch from it).

```bash
gh repo create my-org/my-cache --public --clone
cd my-cache
```

### 2. Initialize the Cache Structure

Create the `nix-cache-info` file that Nix expects at the root of any binary cache:

```bash
cat > nix-cache-info <<'EOF'
StoreDir: /nix/store
Priority: 40
EOF
```

The `Priority` value determines the order Nix checks substituters. Lower values are checked first. The official cache.nixos.org uses priority 40; set yours equal or higher depending on preference.

### 3. Create the Directory Structure

```bash
mkdir -p nar logs manifests
touch index.txt
```

### 4. Generate a Signing Key Pair

Nix requires NAR files to be signed by a trusted key. Generate a key pair:

```bash
nix key generate-secret --key-name my-cache-1 > nix-signing-key.private
nix key convert-secret-to-public < nix-signing-key.private > nix-signing-key.public
```

Keep `nix-signing-key.private` secret (set it as `NIX_SIGNING_KEY` in your CI environment). The public key is what consumers add to `extra-trusted-public-keys`.

### 5. Commit and Push

```bash
git add nix-cache-info index.txt nar/ logs/ manifests/
git commit -m "Initialize binary cache"
git push origin main
```

## Configuring as a Nix Substituter

Add the cache as a substituter in your project's `flake.nix`:

```nix
{
  nixConfig = {
    extra-substituters = [ "https://raw.githubusercontent.com/OWNER/REPO/main" ];
    extra-trusted-public-keys = [ "my-cache-1:BASE64-PUBLIC-KEY" ];
  };

  # ... rest of flake
}
```

Replace `OWNER/REPO` with your cache repository path and `my-cache-1:BASE64-PUBLIC-KEY` with the contents of your public key file.

Once configured, Nix will automatically check the cache before building:

```bash
nix build .#release
# Fetches from cache if available, builds locally if not
```

### Private Repositories

When the cache repository is private, Nix must authenticate its HTTP requests to `raw.githubusercontent.com`. Use the `netrc-file` mechanism, which is Nix's built-in support for HTTP binary cache authentication.

#### 1. Create a GitHub Token

Create a GitHub Personal Access Token:
- **Classic token**: needs `repo` scope
- **Fine-grained token**: needs `Contents: Read` permission on the cache repository

#### 2. Create a netrc File

```bash
mkdir -p ~/.config/nix

cat > ~/.config/nix/netrc <<'EOF'
machine raw.githubusercontent.com
login x-access-token
password ghp_YOUR_TOKEN
EOF

chmod 600 ~/.config/nix/netrc
```

Replace `ghp_YOUR_TOKEN` with your actual token.

#### 3. Configure Nix to Use the netrc File

Add to `~/.config/nix/nix.conf`:

```
netrc-file = /home/YOUR_USER/.config/nix/netrc
```

The path must be absolute — `netrc-file` does not expand `~`.

#### 4. Multi-User (Daemon) Installs

On multi-user Nix installs, the daemon runs as root and does not read per-user config. Place the netrc file and config system-wide instead:

```bash
sudo tee /etc/nix/netrc <<'EOF'
machine raw.githubusercontent.com
login x-access-token
password ghp_YOUR_TOKEN
EOF

sudo chmod 600 /etc/nix/netrc
```

Add to `/etc/nix/nix.conf`:

```
netrc-file = /etc/nix/netrc
```

#### 5. Verify

```bash
nix path-info --store https://raw.githubusercontent.com/OWNER/REPO/main /nix/store/SOME-HASH
```

If authentication is working, this returns the path info. Without it, Nix reports the path as unavailable.

## Why Uncompressed NARs

NAR files are stored without compression (`.nar`, not `.nar.zst`). This is a deliberate design choice that exploits Git's delta compression algorithm for superior storage efficiency across multiple builds.

### How Git Delta Compression Works

When Git creates packfiles (during `git gc`, `git push`, or `git repack`), it searches for objects with similar content and stores only the byte-level differences between them. This happens transparently at the storage layer.

Compressed NARs defeat this mechanism. Compression algorithms like zstd produce entirely different byte streams for inputs that differ by even a single byte, making delta compression ineffective. Uncompressed NARs preserve the raw byte similarity between builds, allowing Git to find and exploit shared sequences.

### Benefits

- **Cross-variant deduplication**: A release build and a debug build of the same source share the vast majority of their bytes. Git stores the second variant as a small delta against the first.
- **Incremental version sync**: When a new version is built, only the changed portions of the NAR transfer during `git push` and `git fetch`.
- **No LFS required**: Because Git's delta compression keeps the effective storage size small, the repository works within standard Git hosting limits without requiring Git LFS.
- **Server-side optimization**: GitHub automatically runs `git gc` and packfile optimization on hosted repositories.

### Storage Efficiency Comparison

The following table illustrates the difference for a project with 8 variants across two versions:

| Approach | v1.0 (8 variants) | v1.1 (8 variants) | Effective Total |
|---|---|---|---|
| Compressed NARs (zstd) | 10 MB | 10 MB | 20 MB |
| Uncompressed NARs + Git delta | 40 MB raw | ~500 KB delta | ~40.5 MB effective |

While the raw uncompressed files are larger, Git's delta compression across similar variants and versions results in a smaller effective repository size that grows slowly over time. The advantage compounds with each additional version because new builds delta against all prior builds in the packfile.

## Storage Layout

```
PUSH/
├── nix-cache-info           # Cache metadata (StoreDir, Priority)
├── nar/
│   └── <hash>.nar           # Uncompressed NAR files
├── <hash>.narinfo           # Store path metadata and signatures
├── logs/
│   └── <hash>.log           # Build logs (content-addressed by store path hash)
├── manifests/
│   └── <variant>.json       # Per-variant latest build info
├── index.txt                # Complete store path index
└── upload.sh                # Upload script for pushing artifacts via GitHub API
```

- **nix-cache-info**: Required by the Nix substituter protocol. Contains `StoreDir` and `Priority`.
- **nar/**: Contains the actual build artifacts as uncompressed Nix Archives.
- **\<hash\>.narinfo**: Metadata files at the repository root, one per store path. These tell Nix where to find the NAR, its hash, size, references, and signature.
- **logs/**: Build logs named by the store path hash for direct lookup.
- **manifests/**: JSON files tracking the latest build for each variant (release, debug, asan, etc.).
- **index.txt**: A flat-file index of all store paths in the cache.

## upload.sh Usage

The `upload.sh` script uploads NAR files and metadata to the cache repository via the GitHub API. It automatically selects the appropriate API based on file size.

### Basic Usage

```bash
# Upload specific files
./upload.sh export/nar/*.nar

# Upload an entire export directory (recursively)
./upload.sh export/

# Preview what would be uploaded without making changes
./upload.sh --dry-run export/
```

### Options

| Option | Default | Description |
|---|---|---|
| `--owner OWNER` | From config or `CACHE_OWNER` env | GitHub repository owner |
| `--repo REPO` | From config or `CACHE_REPO` env | GitHub repository name |
| `--branch BRANCH` | `main` | Target branch for uploads |
| `--prefix PATH` | Auto-detected by file type | Path prefix in repository |
| `--dry-run` | Off | Show what would be uploaded without uploading |
| `-h`, `--help` | | Show usage information |

### Examples

```bash
# Upload NARs to a specific repository
./upload.sh --owner my-org --repo my-cache --branch main export/nar/*.nar

# Upload logs with an explicit prefix
./upload.sh --prefix logs export/logs/*.log

# Dry run to verify paths before uploading
./upload.sh --dry-run export/
```

The script auto-detects the remote path based on file extension when `--prefix` is not specified:
- `.nar` files go to `nar/`
- `.narinfo` files go to the repository root
- `.log` files go to `logs/`
- `.json` files from a `manifests/` directory go to `manifests/`

### Configuration Resolution

The script resolves the owner and repo in the following order:
1. Command-line arguments (`--owner`, `--repo`)
2. Environment variables (`CACHE_OWNER`, `CACHE_REPO`)
3. PULL configuration file (`../PULL/cache/config.json`)

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `CACHE_REPO_TOKEN` | Yes (or `GITHUB_TOKEN`) | GitHub token with write access to the cache repository |
| `GITHUB_TOKEN` | Fallback | Used if `CACHE_REPO_TOKEN` is not set |
| `CACHE_OWNER` | No | Default repository owner (overridden by `--owner`) |
| `CACHE_REPO` | No | Default repository name (overridden by `--repo`) |

The token requires the `contents: write` permission on the cache repository.

## Content-Addressed Logging

Build logs are stored using the Nix store path hash as the filename, enabling direct lookup without an index:

```
/nix/store/abc123def456...-package-1.0  -->  logs/abc123def456....log
```

| Benefit | Description |
|---|---|
| Direct lookup | Given a store path, the build log filename is immediately known |
| Immutability | Each store path hash is unique; logs are never overwritten |
| GC-friendly | When garbage collecting a store path, its log can be deleted by hash |
| Dashboard linking | The POST dashboard links directly to logs via the hash |

## narinfo Format Reference

Each `.narinfo` file at the repository root describes a single cached store path:

```
StorePath: /nix/store/<hash>-<name>-<version>
URL: nar/<hash>.nar
Compression: none
FileHash: sha256:<hash>
FileSize: <bytes>
NarHash: sha256:<hash>
NarSize: <bytes>
References: <space-separated store paths>
Sig: <key-name>:<base64-signature>
```

| Field | Description |
|---|---|
| `StorePath` | Full Nix store path this entry describes |
| `URL` | Relative path to the NAR file within the cache |
| `Compression` | Always `none` (uncompressed NARs for Git delta compression) |
| `FileHash` | SHA-256 hash of the NAR file on disk |
| `FileSize` | Size of the NAR file in bytes |
| `NarHash` | SHA-256 hash of the NAR content |
| `NarSize` | Size of the NAR content in bytes |
| `References` | Other store paths this derivation depends on |
| `Sig` | Cryptographic signature for the store path (key name + base64 signature) |

## manifest.json Format Reference

Each file in `manifests/` tracks the latest successful build for a variant:

```json
{
  "variant": "release",
  "store_path": "/nix/store/abc123...-PROJ-release-1.0.0",
  "path_hash": "abc123...",
  "file_hash": "sha256:...",
  "file_size": 1234567,
  "rev": "abc123def456...",
  "version": "1.0.0",
  "timestamp": "2024-01-15T10:30:00Z"
}
```

| Field | Description |
|---|---|
| `variant` | Build variant name (release, debug, asan, ubsan, tsan, msan, coverage, fuzz) |
| `store_path` | Full Nix store path of the build output |
| `path_hash` | Hash portion of the store path (used for log and narinfo lookup) |
| `file_hash` | SHA-256 hash of the NAR file |
| `file_size` | Size of the NAR file in bytes |
| `rev` | Git commit SHA of the source that was built |
| `version` | Version string of the built package |
| `timestamp` | ISO 8601 timestamp of when the build completed |

## File Size Limits

The upload script uses different GitHub APIs depending on file size:

| File Size | API Used | Method |
|---|---|---|
| < 1 MB | [Contents API](https://docs.github.com/en/rest/repos/contents) | Base64-encoded content in the request body |
| 1 - 100 MB | [Blobs API](https://docs.github.com/en/rest/git/blobs) | Base64 upload, then assembled via Git Tree API |
| > 100 MB | Not supported | Split the package or use Git LFS |

Most narinfo files, logs, and manifests fall under 1 MB. NAR files for typical C++ projects are usually under 100 MB. If a NAR exceeds 100 MB, consider splitting the package into smaller outputs.

## Dependencies

- **curl** - HTTP requests to the GitHub API
- **jq** - JSON parsing and construction
- **base64** - Encoding file content for API uploads

All three are available in the buildbuild Nix dev shell (`nix develop`).

## License

MIT
