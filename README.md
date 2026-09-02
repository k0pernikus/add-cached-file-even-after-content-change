# `ADD --checksum` ignores the URL in its cache key

`ADD --checksum=sha256:<digest> <url> <dest>` keys its cache on the **declared digest and the URL's last path
segment**, not on the URL. Two different URLs that share a basename therefore share a cache entry, and a build
whose declared digest is stale for its URL receives the previously cached content. There is no fetch, no
verification, and the build succeeds.

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
| 2 | `folder_2/same_file` | ALPHA's *(stale)* | **`ALPHA`** | `BRAVO`, or a failed build |
| 3 | `folder_2/same_file` | BRAVO's | `BRAVO` | `BRAVO` |
| 4 | `folder_2/same_file` | ALPHA's, plus `--no-cache` | **`ALPHA`** | a fetch |
| 5 | `folder_2/same_file` | a digest no build has used | *build fails* | *build fails* |

Build 2 logs the reused layer:

```text
#6 [1/1] ADD --checksum=sha256:1921b918... http://127.0.0.1:8099/folder_2/same_file /payload
#6 CACHED
```

Build 3 confirms that URL serves different bytes. Build 2's content therefore came from the cache, not from
the server.

Build 5 uses a digest no build has populated. It fetches, compares, and fails:

```text
ERROR: failed to build: failed to solve: digest mismatch
  sha256:8a51c1b8...: sha256:380ff935...
```

`--no-cache` does not reach the HTTP source cache. Build 4 passes it, logs `#5 CACHED`, and returns `ALPHA`.
Once an entry exists for a (basename, declared digest) pair, no build flag surfaces the mismatch.

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

## Suggested fix

Include the URL in the cache key. An unchanged Dockerfile keeps the same URL, so it still hits the cache and
still skips the fetch. Only a changed URL misses, and that fetch is what catches a stale digest.

## Impact

The wrong content ships and no build reports it. A Dockerfile can declare one version, install the binary of
an earlier version, and produce a successful build.

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

The final `diff` reports:

```text
1c1
< BRAVO
---
> ALPHA
```
