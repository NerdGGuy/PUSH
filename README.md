# PUSH - Binary Cache

Git-based binary cache storing uncompressed NAR files. Uses Git's native delta compression to efficiently deduplicate similar builds across variants and versions.

## Usage

Configure Nix to use this cache as a substituter:

```nix
{
  nixConfig = {
    extra-substituters = [ "https://raw.githubusercontent.com/ORG/CACHE-REPO/main" ];
    extra-trusted-public-keys = [ "cache-name:BASE64-PUBLIC-KEY" ];
  };
}
```

Build with automatic cache lookup:

```bash
nix build github:org/project#release
# Fetches from cache if available, builds locally if not
```

## Storage Layout

```
/
├── nix-cache-info           # StoreDir, Priority
├── nar/
│   └── <hash>.nar           # Uncompressed NAR files
├── <hash>.narinfo           # Store path metadata
├── logs/
│   └── <hash>.log           # Build logs (content-addressed)
├── manifests/
│   └── <variant>.json       # Per-variant path listings
└── index.txt                # Complete path index
```

## Why Uncompressed?

NAR files are stored without compression (`.nar`, not `.nar.zst`) to enable Git delta compression:

| Benefit | Description |
|---------|-------------|
| Delta compression | Git packfiles find shared byte sequences between similar files |
| Cross-variant deduplication | Release vs debug of same source share most bytes |
| Incremental sync | Only changed portions transfer on push/fetch |
| No LFS required | Works within standard Git hosting limits |
| Server-side optimization | GitHub handles packfile compression |

### Storage Efficiency

| Approach | v1.0 Size | v1.1 Size | Total |
|----------|-----------|-----------|-------|
| Compressed (zstd) | 10 MB | 10 MB | 20 MB |
| Uncompressed + Git delta | 40 MB | ~500 KB delta | ~40.5 MB |

## Content-Addressed Logging

Build logs use the Nix store path hash as filename:

```
/nix/store/abc123def456...-package-1.0  →  logs/abc123def456....log
```

| Benefit | Description |
|---------|-------------|
| Direct lookup | Given a store path, immediately find its build log |
| Immutability | Logs are never overwritten |
| GC-friendly | Delete log when garbage collecting store path |
| Dashboard linking | Status repo links directly via hash |

## File Size Limits

| Size | API | Notes |
|------|-----|-------|
| < 1 MB | Contents API | Base64 in request body |
| 1-100 MB | Blobs API | Base64 upload |
| > 100 MB | Not supported | Split package or use LFS |

## narinfo Format

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

## Dependencies

- Git
- Nix (for NAR operations)

## License

MIT
