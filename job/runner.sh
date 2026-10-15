#!/bin/sh
# Runs INSIDE the migration Job pod (rclone image, busybox sh).
# It is shipped to the pod through a ConfigMap by migrate.sh. Do not run it locally.
#
# MODE=inspect : detect MinIO layout, list buckets/sizes, check mapping and Scaleway access
# MODE=copy    : rclone copy each mapped bucket dir -> Scaleway bucket (incremental, re-runnable)
# MODE=verify  : rclone check each mapped bucket dir against its Scaleway bucket
set -eu

DATA_DIR="/export"
MAP_FILE="/migration/buckets.map"
MODE="${MODE:?MODE must be inspect, copy or verify}"
BUCKET_PREFIX="${BUCKET_PREFIX:?BUCKET_PREFIX is required}"
TRANSFERS="${TRANSFERS:-8}"
DRY_RUN="${DRY_RUN:-false}"
CREATE_BUCKETS="${CREATE_BUCKETS:-true}"
VERIFY_FLAGS="${VERIFY_FLAGS:-}"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# Prints "<source-dir> <destination-bucket>" for every non-comment line of the map.
mapped_entries() {
  awk -v p="$BUCKET_PREFIX" '!/^[[:space:]]*(#|$)/ { print $1, p "-" $2 }' "$MAP_FILE"
}

dest_for() {
  mapped_entries | awk -v s="$1" '$1 == s { print $2; exit }'
}

# MinIO single-drive "fs" mode stores objects as plain files: /export/<bucket>/<key>.
# "xl" (erasure / xl-single) stores them as xl.meta + part files and cannot be copied as-is.
detect_format() {
  f="$DATA_DIR/.minio.sys/format.json"
  if [ -f "$f" ]; then
    if grep -Eq '"format"[[:space:]]*:[[:space:]]*"fs"' "$f"; then echo "fs"; return; fi
    if grep -Eq '"format"[[:space:]]*:[[:space:]]*"xl' "$f"; then echo "xl"; return; fi
  fi
  if [ -n "$(find "$DATA_DIR" -maxdepth 5 -name xl.meta 2>/dev/null | head -n 1)" ]; then
    echo "xl"; return
  fi
  echo "unknown"
}

do_inspect() {
  fmt="$(detect_format)"
  log "MinIO backend layout: $fmt"
  case "$fmt" in
    fs) log "OK: objects are plain files, a direct copy is possible." ;;
    xl) log "ERROR: xl layout (xl.meta files). Direct copy is NOT possible, see README section 'xl layout'." ;;
    *)  log "WARNING: layout not detected. Inspect $DATA_DIR/.minio.sys/format.json manually." ;;
  esac

  echo
  log "Bucket directories found on the volume:"
  printf '  %-28s %8s %12s   %s\n' "SOURCE" "SIZE" "FILES" "DESTINATION"
  for d in "$DATA_DIR"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    size="$(du -sh "$d" 2>/dev/null | cut -f1)"
    count="$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')"
    dest="$(dest_for "$name")"
    [ -n "$dest" ] || dest="NOT MAPPED (skipped)"
    printf '  %-28s %8s %12s   %s\n' "$name" "$size" "$count" "$dest"
  done

  echo
  log "Map entries with no matching directory (will be skipped):"
  mapped_entries | while read -r src dest; do
    if [ ! -d "$DATA_DIR/$src" ]; then printf '  %s -> %s\n' "$src" "$dest"; fi
  done

  echo
  log "Checking Scaleway access (listing buckets)..."
  if rclone lsd scw: </dev/null >/tmp/remote-buckets.txt 2>/tmp/remote-err.txt; then
    log "OK: credentials work."
    mapped_entries | while read -r src dest; do
      if awk '{ print $NF }' /tmp/remote-buckets.txt | grep -qx "$dest"; then state="exists"; else state="missing"; fi
      printf '  %-36s %s\n' "$dest" "$state"
    done
  else
    log "ERROR: cannot list Scaleway buckets:"
    cat /tmp/remote-err.txt
    if grep -Eqi 'x509|certificate' /tmp/remote-err.txt; then
      log "HINT: TLS error. Set SCW_CA_CERT to the endpoint's CA (PEM) in the env file,"
      log "      or SCW_SKIP_TLS_VERIFY=true as a last resort."
    fi
    exit 3
  fi

  [ "$fmt" = "fs" ] || exit 2
}

do_copy() {
  [ "$(detect_format)" = "fs" ] || { log "Refusing to copy: layout is not 'fs' (run inspect)."; exit 2; }
  dry=""
  if [ "$DRY_RUN" = "true" ]; then dry="--dry-run"; log "=== DRY RUN: nothing will be written ==="; fi

  mapped_entries >/tmp/map.txt
  failed=0
  while read -r src dest; do
    if [ ! -d "$DATA_DIR/$src" ]; then log "SKIP  $src (not present on volume)"; continue; fi

    if [ "$CREATE_BUCKETS" = "true" ] && [ -z "$dry" ]; then
      if ! rclone mkdir "scw:$dest" </dev/null; then
        log "FAIL  cannot create bucket $dest"; failed=$((failed + 1)); continue
      fi
    fi

    log "COPY  $src -> scw:$dest"
    if rclone copy "$DATA_DIR/$src" "scw:$dest" $dry \
        --s3-no-check-bucket \
        --transfers "$TRANSFERS" --checkers "$((TRANSFERS * 2))" \
        --fast-list --retries 5 --low-level-retries 20 \
        --stats 60s --stats-one-line --stats-log-level NOTICE </dev/null; then
      log "DONE  $src"
    else
      log "FAIL  $src"; failed=$((failed + 1))
    fi
  done </tmp/map.txt

  [ "$failed" -eq 0 ] || { log "$failed bucket(s) failed. Re-run copy: rclone only sends what is missing."; exit 1; }
  log "All buckets copied."
}

do_verify() {
  mapped_entries >/tmp/map.txt
  failed=0
  while read -r src dest; do
    [ -d "$DATA_DIR/$src" ] || continue
    log "CHECK $src <-> scw:$dest"
    # --one-way: only report objects missing or different on Scaleway (extra objects there are fine)
    # shellcheck disable=SC2086
    if rclone check "$DATA_DIR/$src" "scw:$dest" --one-way --fast-list \
        --checkers "$((TRANSFERS * 2))" $VERIFY_FLAGS </dev/null; then
      log "OK    $src"
    else
      log "DIFF  $src"; failed=$((failed + 1))
    fi
  done </tmp/map.txt

  [ "$failed" -eq 0 ] || { log "$failed bucket(s) have differences."; exit 1; }
  log "All buckets match."
}

log "rclone $(rclone version 2>/dev/null | head -n 1 | awk '{print $2}') | mode=$MODE prefix=$BUCKET_PREFIX"
if [ "${RCLONE_NO_CHECK_CERTIFICATE:-false}" = "true" ]; then
  log "WARNING: TLS certificate verification is disabled"
elif [ -n "${RCLONE_CA_CERT:-}" ]; then
  [ -r "$RCLONE_CA_CERT" ] || { log "ERROR: CA certificate $RCLONE_CA_CERT not readable"; exit 3; }
  log "TLS: trusting CA $RCLONE_CA_CERT"
fi
case "$MODE" in
  inspect) do_inspect ;;
  copy)    do_copy ;;
  verify)  do_verify ;;
  *)       log "Unknown MODE '$MODE'"; exit 64 ;;
esac
