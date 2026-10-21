#!/usr/bin/env bash
# Copy GitLab's bundled MinIO data (from its PVC) to Scaleway Object Storage.
#
# Usage:  ./migrate.sh <env-file> <inspect|copy|verify|cleanup>
#
#   inspect  Detect MinIO layout, list bucket dirs + sizes, check mapping and Scaleway credentials
#   copy     Copy every mapped bucket (incremental: safe to re-run). DRY_RUN=true for a dry run
#   verify   Compare source and destination for every mapped bucket
#   cleanup  Delete the migration Jobs, ConfigMap and (optionally) the credentials Secret
#
# Credentials: the Secret named SCW_SECRET_NAME is reused if it exists, otherwise it is
# created from the SCW_ACCESS_KEY / SCW_SECRET_KEY environment variables (never stored in files).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="app.kubernetes.io/name=minio-migration"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 64; }

[[ $# -eq 2 ]] || usage
ENV_FILE="$1"
CMD="$2"
[[ -f "$ENV_FILE" ]] || die "env file not found: $ENV_FILE"

# Keep DRY_RUN / ASSUME_YES given on the command line even if the env file sets them
CLI_DRY_RUN="${DRY_RUN:-}"
CLI_ASSUME_YES="${ASSUME_YES:-}"
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${NAMESPACE:?set NAMESPACE in $ENV_FILE}"
: "${PVC_NAME:?set PVC_NAME in $ENV_FILE}"
: "${BUCKET_PREFIX:?set BUCKET_PREFIX in $ENV_FILE}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
SCW_REGION="${SCW_REGION:-fr-par}"
SCW_ENDPOINT="${SCW_ENDPOINT:-s3.${SCW_REGION}.scw.cloud}"
SCW_SECRET_NAME="${SCW_SECRET_NAME:-minio-migration-scw}"
S3_PROVIDER="${S3_PROVIDER:-Scaleway}"
S3_STORAGE_CLASS="${S3_STORAGE_CLASS-STANDARD}"
BUCKET_MAP="${BUCKET_MAP:-buckets.map}"
RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:1.68.2}"
RUN_AS_UID="${RUN_AS_UID-1000}"   # empty = let the platform pick (OpenShift restricted-v2)
TRANSFERS="${TRANSFERS:-8}"
CREATE_BUCKETS="${CREATE_BUCKETS:-true}"
VERIFY_FLAGS="${VERIFY_FLAGS:-}"
NODE_NAME="${NODE_NAME:-}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-}"
SCW_CA_CERT="${SCW_CA_CERT:-}"
SCW_SKIP_TLS_VERIFY="${SCW_SKIP_TLS_VERIFY:-false}"
DRY_RUN="${CLI_DRY_RUN:-${DRY_RUN:-false}}"
ASSUME_YES="${CLI_ASSUME_YES:-${ASSUME_YES:-false}}"
ENV_NAME="$(basename "$ENV_FILE" .env)"

[[ "$BUCKET_MAP" = /* ]] || BUCKET_MAP="$SCRIPT_DIR/$BUCKET_MAP"
[[ -f "$BUCKET_MAP" ]] || die "bucket map not found: $BUCKET_MAP"
if [[ -n "$SCW_CA_CERT" ]]; then
  [[ "$SCW_CA_CERT" = /* ]] || SCW_CA_CERT="$SCRIPT_DIR/$SCW_CA_CERT"
  [[ -f "$SCW_CA_CERT" ]] || die "CA certificate not found: $SCW_CA_CERT"
  grep -q 'BEGIN CERTIFICATE' "$SCW_CA_CERT" || die "CA certificate is not PEM: $SCW_CA_CERT"
fi
[[ "$SCW_SKIP_TLS_VERIFY" == true || "$SCW_SKIP_TLS_VERIFY" == false ]] \
  || die "SCW_SKIP_TLS_VERIFY must be true or false"

KUBECTL=(kubectl)
[[ -n "$KUBE_CONTEXT" ]] && KUBECTL+=(--context "$KUBE_CONTEXT")
k()  { "${KUBECTL[@]}" -n "$NAMESPACE" "$@"; }
kc() { "${KUBECTL[@]}" "$@"; }   # cluster-scoped resources

preflight() {
  command -v kubectl >/dev/null || die "kubectl not found"
  local ctx
  ctx="${KUBE_CONTEXT:-$(kubectl config current-context)}"
  log "Environment : $ENV_NAME"
  log "Context     : $ctx"
  log "Namespace   : $NAMESPACE"
  k get pvc "$PVC_NAME" >/dev/null 2>&1 || die "PVC $PVC_NAME not found in $NAMESPACE"

  local pv modes size
  pv="$(k get pvc "$PVC_NAME" -o jsonpath='{.spec.volumeName}')"
  modes="$(k get pvc "$PVC_NAME" -o jsonpath='{.spec.accessModes}')"
  size="$(k get pvc "$PVC_NAME" -o jsonpath='{.status.capacity.storage}')"
  log "PVC         : $PVC_NAME ($size, $modes, PV $pv)"
  [[ "$modes" == *ReadWriteOncePod* ]] && warn "ReadWriteOncePod: the MinIO pod must be deleted before the Job can mount the volume"

  # A ReadWriteOnce block volume can only be mounted on the node it is attached to.
  if [[ -z "$NODE_NAME" ]]; then
    NODE_NAME="$(kc get volumeattachment \
      -o jsonpath="{range .items[?(@.spec.source.persistentVolumeName=='$pv')]}{.spec.nodeName}{'\n'}{end}" \
      2>/dev/null | head -n 1 || true)"
  fi
  if [[ -n "$NODE_NAME" ]]; then
    log "Node        : $NODE_NAME (volume attached there, Job pinned to it)"
  else
    log "Node        : volume not attached, scheduler will choose"
  fi
  log "Destination : ${BUCKET_PREFIX}-<suffix> @ $SCW_ENDPOINT ($SCW_REGION, provider $S3_PROVIDER)"
  log "Run as UID  : ${RUN_AS_UID:-assigned by the platform} (service account ${SERVICE_ACCOUNT:-default})"
  if [[ -n "$SERVICE_ACCOUNT" ]]; then
    k get serviceaccount "$SERVICE_ACCOUNT" >/dev/null 2>&1 \
      || die "service account $SERVICE_ACCOUNT not found in $NAMESPACE"
  fi
  if [[ "$SCW_SKIP_TLS_VERIFY" == true ]]; then
    warn "TLS certificate verification is DISABLED for $SCW_ENDPOINT"
  elif [[ -n "$SCW_CA_CERT" ]]; then
    log "TLS         : trusting CA $SCW_CA_CERT"
  fi
}

ensure_secret() {
  if k get secret "$SCW_SECRET_NAME" >/dev/null 2>&1; then
    log "Using existing secret $SCW_SECRET_NAME"
    return
  fi
  [[ -n "${SCW_ACCESS_KEY:-}" && -n "${SCW_SECRET_KEY:-}" ]] \
    || die "secret $SCW_SECRET_NAME not found: export SCW_ACCESS_KEY and SCW_SECRET_KEY to create it"
  k create secret generic "$SCW_SECRET_NAME" \
    --from-literal=access_key="$SCW_ACCESS_KEY" \
    --from-literal=secret_key="$SCW_SECRET_KEY" >/dev/null
  k label secret "$SCW_SECRET_NAME" "$LABEL" >/dev/null
  log "Created secret $SCW_SECRET_NAME"
}

ensure_configmap() {
  local files=(--from-file=runner.sh="$SCRIPT_DIR/job/runner.sh" --from-file=buckets.map="$BUCKET_MAP")
  # A CA certificate is public data, a ConfigMap is fine for it
  [[ -n "$SCW_CA_CERT" ]] && files+=(--from-file=ca.crt="$SCW_CA_CERT")
  k create configmap minio-migration-files "${files[@]}" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k label configmap minio-migration-files "$LABEL" --overwrite >/dev/null
}

render_job() {
  local mode="$1" node_line="" sa_line="" tls_env="" uid_lines="" sc_env=""
  [[ -n "$NODE_NAME" ]] && node_line="nodeName: ${NODE_NAME}"
  # OpenShift: reuse the MinIO service account so the Job gets the same SCC (and UID)
  [[ -n "$SERVICE_ACCOUNT" ]] && sa_line="serviceAccountName: ${SERVICE_ACCOUNT}"
  # OpenShift SCCs reject a fixed UID outside the namespace range: leave it unset there
  [[ -n "$RUN_AS_UID" ]] && uid_lines=$'\n'"        runAsUser: ${RUN_AS_UID}"$'\n'"        runAsGroup: ${RUN_AS_UID}"
  [[ -n "$S3_STORAGE_CLASS" ]] && sc_env=$'\n'"            - { name: RCLONE_CONFIG_SCW_STORAGE_CLASS, value: ${S3_STORAGE_CLASS} }"
  # rclone global flags --ca-cert / --no-check-certificate, set through the environment
  [[ -n "$SCW_CA_CERT" ]] && tls_env+=$'\n            - { name: RCLONE_CA_CERT, value: /migration/ca.crt }'
  [[ "$SCW_SKIP_TLS_VERIFY" == true ]] && tls_env+=$'\n            - { name: RCLONE_NO_CHECK_CERTIFICATE, value: "true" }'
  cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-migration-${mode}
  labels:
    app.kubernetes.io/name: minio-migration
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 604800
  template:
    metadata:
      labels:
        app.kubernetes.io/name: minio-migration
    spec:
      restartPolicy: Never
      ${node_line}
      ${sa_line}
      securityContext:
        runAsNonRoot: true${uid_lines}
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: rclone
          image: ${RCLONE_IMAGE}
          command: ["sh", "/migration/runner.sh"]
          env:
            - { name: MODE, value: "${mode}" }
            - { name: DRY_RUN, value: "${DRY_RUN}" }
            - { name: TRANSFERS, value: "${TRANSFERS}" }
            - { name: BUCKET_PREFIX, value: "${BUCKET_PREFIX}" }
            - { name: CREATE_BUCKETS, value: "${CREATE_BUCKETS}" }
            - { name: VERIFY_FLAGS, value: "${VERIFY_FLAGS}" }
            - { name: HOME, value: /tmp }
            - { name: RCLONE_CONFIG, value: /tmp/rclone.conf }
            - { name: RCLONE_CONFIG_SCW_TYPE, value: s3 }
            - { name: RCLONE_CONFIG_SCW_PROVIDER, value: "${S3_PROVIDER}" }
            - { name: RCLONE_CONFIG_SCW_ENV_AUTH, value: "false" }
            - { name: RCLONE_CONFIG_SCW_REGION, value: "${SCW_REGION}" }
            - { name: RCLONE_CONFIG_SCW_ENDPOINT, value: "${SCW_ENDPOINT}" }
            - { name: RCLONE_CONFIG_SCW_ACL, value: private }${sc_env}
            - { name: RCLONE_CONFIG_SCW_CHUNK_SIZE, value: 32M }
            - { name: RCLONE_CONFIG_SCW_UPLOAD_CONCURRENCY, value: "2" }${tls_env}
            - name: RCLONE_CONFIG_SCW_ACCESS_KEY_ID
              valueFrom: { secretKeyRef: { name: ${SCW_SECRET_NAME}, key: access_key } }
            - name: RCLONE_CONFIG_SCW_SECRET_ACCESS_KEY
              valueFrom: { secretKeyRef: { name: ${SCW_SECRET_NAME}, key: secret_key } }
          resources:
            requests: { cpu: 250m, memory: 256Mi }
            limits: { memory: 1Gi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { name: data, mountPath: /export, readOnly: true }
            - { name: files, mountPath: /migration, readOnly: true }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
            readOnly: true
        - name: files
          configMap:
            name: minio-migration-files
        - name: tmp
          emptyDir: {}
EOF
}

wait_for_pod() {
  local job="$1" phase=""
  for _ in $(seq 1 60); do
    phase="$(k get pods -l "job-name=$job" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    case "$phase" in Running|Succeeded|Failed) return 0 ;; esac
    sleep 5
  done
  warn "pod for $job did not start within 5 minutes:"
  k describe pods -l "job-name=$job" | tail -n 20 >&2
  return 1
}

run_job() {
  local mode="$1" job="minio-migration-$1" logfile
  ensure_secret
  ensure_configmap
  k delete job "$job" --ignore-not-found --wait=true >/dev/null
  render_job "$mode" | k apply -f - >/dev/null
  log "Started job $job"
  wait_for_pod "$job"

  mkdir -p "$SCRIPT_DIR/logs"
  logfile="$SCRIPT_DIR/logs/${ENV_NAME}-${mode}$([[ "$DRY_RUN" == true && "$mode" == copy ]] && echo -dryrun)-$(date +%Y%m%d-%H%M%S).log"
  k logs -f "job/$job" 2>&1 | tee "$logfile" || true

  local ok fail
  for _ in $(seq 1 30); do
    ok="$(k get job "$job" -o jsonpath='{.status.succeeded}')"
    fail="$(k get job "$job" -o jsonpath='{.status.failed}')"
    if [[ "${ok:-0}" -ge 1 ]]; then log "Job $job succeeded (log: $logfile)"; return 0; fi
    if [[ "${fail:-0}" -ge 1 ]]; then die "Job $job failed (log: $logfile)"; fi
    sleep 2
  done
  warn "log stream ended but job still running. Follow it with:"
  warn "  kubectl -n $NAMESPACE logs -f job/$job"
}

confirm() {
  [[ "$ASSUME_YES" == true ]] && return 0
  read -r -p "Proceed with '$CMD' on environment '$ENV_NAME'? [y/N] " answer
  [[ "$answer" =~ ^[yY]$ ]] || die "aborted"
}

cleanup() {
  k delete job -l "$LABEL" --ignore-not-found
  k delete configmap minio-migration-files --ignore-not-found
  read -r -p "Also delete secret $SCW_SECRET_NAME? [y/N] " answer
  [[ "$answer" =~ ^[yY]$ ]] && k delete secret "$SCW_SECRET_NAME" --ignore-not-found
  return 0
}

preflight
case "$CMD" in
  inspect) run_job inspect ;;
  copy)
    [[ "$DRY_RUN" == true ]] && log "DRY RUN enabled" || confirm
    run_job copy ;;
  verify)  run_job verify ;;
  cleanup) cleanup ;;
  *)       usage ;;
esac
