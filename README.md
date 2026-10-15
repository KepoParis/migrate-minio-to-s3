# GitLab MinIO → Scaleway Object Storage migration

Copies the objects stored on GitLab's bundled MinIO volume (`gitlab-minio` PVC) into
Scaleway buckets, one bucket per GitLab object type. Nothing needs the MinIO image:
a short-lived rclone Job mounts the PVC **read-only** and uploads its files.

```
minio-migration/
├── migrate.sh        # run from your workstation (kubectl)
├── job/runner.sh     # runs inside the Job pod (shipped via ConfigMap)
├── buckets.map       # MinIO directory -> Scaleway bucket suffix
└── envs/example.env  # one file per environment
```

## How it works

1. `migrate.sh` reads an env file, finds the node the PVC is attached to (RWO volume)
   and pins the Job to it.
2. It creates a Secret with the Scaleway keys and a ConfigMap with `runner.sh` + `buckets.map`.
3. The Job (rclone image, non-root, read-only rootfs) runs in `inspect`, `copy` or `verify` mode.
4. Logs are streamed to your terminal and saved in `logs/<env>-<mode>-<timestamp>.log`.

Every step is idempotent: `rclone copy` only uploads missing or changed files, so an
interrupted copy is resumed by running it again.

## Prerequisites

- `kubectl` access to the namespace (create Job / Secret / ConfigMap, read VolumeAttachments).
- A Scaleway API key with Object Storage write access on the target project.
- The cluster can pull `rclone/rclone` from Docker Hub (or set `RCLONE_IMAGE` to a mirror).

## Process (repeat for each environment)

```bash
# 1. Configure the environment
cp envs/example.env envs/prod.env        # set KUBE_CONTEXT, NAMESPACE, BUCKET_PREFIX...
export SCW_ACCESS_KEY=SCWXXXXXXXXXXXXXXXXX
export SCW_SECRET_KEY=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# 2. Inspect: layout, bucket dirs, sizes, mapping, Scaleway credentials
./migrate.sh envs/prod.env inspect
#    -> must say "layout: fs". Adjust buckets.map if a directory shows "NOT MAPPED".

# 3. Dry run: shows what would be transferred, writes nothing
DRY_RUN=true ./migrate.sh envs/prod.env copy

# 4. Real copy (asks for confirmation; ASSUME_YES=true for CI)
./migrate.sh envs/prod.env copy

# 5. Verify every object exists on Scaleway with the same content
./migrate.sh envs/prod.env verify

# 6. Once GitLab runs on Scaleway and is validated
./migrate.sh envs/prod.env cleanup
```

Only after step 5 is green **and** GitLab has been validated on Scaleway (artifacts
download, LFS files, uploads display, `docker pull` from the registry) should you delete
the `gitlab-minio` PVC.

## Consistency

MinIO is currently down, so no new object reaches the volume: a single copy is consistent.
If MinIO is running in another environment, do a first `copy` while it runs, then stop
writes (disable MinIO / put GitLab in maintenance), run `copy` again (fast, only the delta)
and `verify`, then switch GitLab to Scaleway.

## Bucket mapping

Destination = `<BUCKET_PREFIX>-<suffix>`. Default GitLab chart MinIO buckets are mapped;
`runner-cache` and `tmp` are skipped on purpose. The destination names must match what
you put in the GitLab values (`global.appConfig.*.bucket`, `global.registry.bucket`,
`global.appConfig.backups.bucket`). The registry bucket is copied as-is
(`docker/registry/v2/...`), so **do not** set `rootdirectory` in the registry storage secret.

Scaleway bucket names are unique across all Scaleway customers: pick a distinctive prefix.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod stuck `ContainerCreating`, event `Multi-Attach error` | Volume attached to another node than detected. Set `NODE_NAME` in the env file. |
| Pod rejected by Pod Security admission | Adjust `RUN_AS_UID` or the securityContext in `render_job` to your policy. |
| `permission denied` reading `/export` | Files owned by another UID. Check with `inspect` log / `ls -ln`, set `RUN_AS_UID`. |
| `inspect` exits with `layout: xl` | See below. |
| Copy interrupted / log stream cut | Re-run `copy`; follow a running Job with `kubectl -n <ns> logs -f job/minio-migration-copy`. |
| `x509: certificate signed by unknown authority` | Endpoint uses a self-signed / private CA cert. Set `SCW_CA_CERT=path/to/ca.pem` (shipped in the ConfigMap, passed to rclone `--ca-cert`). `SCW_SKIP_TLS_VERIFY=true` disables verification entirely (last resort). |
| `BucketAlreadyExists` | Name taken by another Scaleway customer: change `BUCKET_PREFIX`. |

### xl layout

If the volume was created with a MinIO version that used the erasure/xl-single format,
objects are split into `xl.meta` + part files and cannot be copied as files. You then
need a running MinIO server on the volume to read it: run the same MinIO release from an
image you mirrored yourself (or build the binary from source), mount the PVC, and replace
the source in `runner.sh` by an rclone S3 remote pointing to that MinIO
(`rclone copy minio:<bucket> scw:<dest>`). The rest of the process is unchanged.
