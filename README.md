# `ADD --checksum` ignores the URL in its cache key

`ADD --checksum=sha256:<digest> <url> <dest>` keys its cache on the **declared digest and the URL's last path
segment**, not on the URL. Two different URLs that share a basename therefore share a cache entry, and a build
whose declared digest is stale for its URL silently receives the previously cached content — with no fetch, no
verification, and a successful build.

## What the repro contains

Two files with the same basename in different directories, with different content:

| path | content | sha256 |
|:---|:---|:---|
| `folder_1/same_file` | `ALPHA` | `1921b918b15842c7fdb115078e610263fac85f159c1d8e0ecec3d89a0faa4005` |
| `folder_2/same_file` | `BRAVO` | `8a51c1b8853b568b5ca25570ef461d6f5a8896f64a952364ed61be1a1e99eb00` |

And a Dockerfile taking the URL and the declared digest as build arguments:

```dockerfile
# syntax=docker/dockerfile:1
FROM scratch

ARG SRC_URL
ARG SRC_SHA256

ADD --checksum=sha256:${SRC_SHA256} ${SRC_URL} /payload
```

## Observed

| build | URL | declared digest | `/payload` | expected |
|:---|:---|:---|:---|:---|
| 1 | `folder_1/same_file` | ALPHA's | `ALPHA` | `ALPHA` |
| 2 | `folder_2/same_file` | ALPHA's *(stale)* | **`ALPHA`** | `BRAVO`, or a loud failure |
| 3 | `folder_2/same_file` | BRAVO's | `BRAVO` | `BRAVO` |
| 4 | `folder_2/same_file` | ALPHA's, plus `--no-cache` | **`ALPHA`** | a fetch |
| 5 | `folder_2/same_file` | a digest nothing published | *build fails* | *build fails* |

Build 2 logs the reused layer:

```text
#6 [1/1] ADD --checksum=sha256:1921b918... http://127.0.0.1:8099/folder_2/same_file /payload
#6 CACHED
```

Build 3 is the control that matters: the URL used in build 2 does serve different bytes, so the cache
produced build 2's wrong content, not the server.

Build 5 shows what the check does when it runs at all — a digest no build has populated forces the fetch and
fails as it should:

```text
ERROR: failed to build: failed to solve: digest mismatch
  sha256:8a51c1b8...: sha256:380ff935...
```

Build 4 is the part that makes this hard to escape: **`--no-cache` does not reach the HTTP source cache.** It
logs `#5 CACHED` and still yields `ALPHA`. So once an entry exists for a (basename, declared digest) pair,
no build-side flag surfaces the inconsistency — the obvious escape hatch does not work.

## Why

In [`source/http/source.go`](https://github.com/moby/buildkit/blob/master/source/http/source.go),
`resolveMetadataStatic` short-circuits as soon as a checksum is declared, returning that digest as the
metadata digest with no network request:

```go
if hs.src.Checksum != "" {
    return &Metadata{
        Digest:   hs.src.Checksum,
        Filename: getFileName(hs.src.URL, hs.src.Filename, nil),
    }, nil
}
```

`CacheKey` then returns `formatCacheKey(md.Filename, md.Digest, md.LastModified)`. The URL is absent, and
`getFileName` reduces it to `path.Base(u.Path)` — so `folder_1/same_file` and `folder_2/same_file` both
contribute `same_file` and the directory is discarded. `LastModified` is nil, because nothing was fetched.

## Why this is worth changing

Content-addressing makes the digest the identity of the *content*, which is why skipping the fetch is correct
when the request is consistent. It does not require dropping the URL from the cache key. Keying on **(URL,
digest)** preserves every cache hit an unchanged Dockerfile gets, which is the whole benefit, and forces a
fetch only when the URL moves — after which verification either confirms the pair or fails loudly. Catching
the inconsistency and skipping the fetch are therefore not mutually exclusive.

The failure is silent and reaches published artifacts: a Dockerfile can declare version N, ship the binary of
version N-1, and produce a clean build under an immutable tag naming the commit that declared N.

## Running it locally

```bash
python3 -m http.server 8099 --bind 127.0.0.1 --directory . &

docker build --build-arg SRC_URL=http://127.0.0.1:8099/folder_1/same_file \
  --build-arg SRC_SHA256=1921b918b15842c7fdb115078e610263fac85f159c1d8e0ecec3d89a0faa4005 \
  --output type=local,dest=out_1 .

docker build --build-arg SRC_URL=http://127.0.0.1:8099/folder_2/same_file \
  --build-arg SRC_SHA256=1921b918b15842c7fdb115078e610263fac85f159c1d8e0ecec3d89a0faa4005 \
  --output type=local,dest=out_2 .

diff folder_2/same_file out_2/payload
```

The final `diff` reports `ALPHA` where `BRAVO` was requested.
