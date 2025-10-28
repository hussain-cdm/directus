#!/bin/bash
set -euo pipefail

if [ -f ".env" ]; then
  set -a
  . ./.env
  set +a
fi

# Read env vars (from .env or environment)
PROD_URL=${DIRECTUS_PROD_URL:-}
PROD_TOKEN=${DIRECTUS_PROD_ADMIN_TOKEN:-}
LOCAL_URL=${DIRECTUS_LOCAL_URL:-"http://localhost:8055"}
LOCAL_TOKEN=${DIRECTUS_LOCAL_TOKEN:-}

TMP_PROD=$(mktemp)
TMP_LOCAL=$(mktemp)
TMP_MERGED=$(mktemp)
cleanup() { rm -f "$TMP_PROD" "$TMP_LOCAL" "$TMP_MERGED"; }
trap cleanup EXIT

# Fetch production and local snapshots in parallel
curl -s -X GET -H "Authorization: Bearer $PROD_TOKEN" "$PROD_URL/schema/snapshot" | jq '.data' > "$TMP_PROD" &
curl -s -X GET -H "Authorization: Bearer $LOCAL_TOKEN" "$LOCAL_URL/schema/snapshot" | jq '.data' > "$TMP_LOCAL" &
wait

# Merge: start from prod, add local-only collections/fields/relations
jq -n \
  --slurpfile P "$TMP_PROD" \
  --slurpfile L "$TMP_LOCAL" \
  '
  ($P[0].collections // [] | map(.collection)) as $prodNames |
  (($L[0].collections // [] | map(.collection)) - $prodNames) as $localOnly |
  
  def onlyLocal(arr): (arr // []) | map(select((.collection // null) as $c | $c and (($localOnly | index($c)) != null)));
  
  {
    version:      ($P[0].version // $L[0].version // 1),
    directus:     ($P[0].directus // $L[0].directus // "unknown"),
    vendor:       ($P[0].vendor // $L[0].vendor // "unknown"),
    collections:  (($P[0].collections  // []) + onlyLocal($L[0].collections)),
    fields:       (($P[0].fields       // []) + onlyLocal($L[0].fields)),
    relations:    (($P[0].relations    // []) + onlyLocal($L[0].relations))
  }
  ' > "$TMP_MERGED"

# Compute diff and apply, printing only request bodies
TMP_DIFF=$(mktemp)
TMP_APPLY=$(mktemp)
cleanup() { rm -f "$TMP_PROD" "$TMP_LOCAL" "$TMP_MERGED" "$TMP_DIFF" "$TMP_APPLY"; }

cat "$TMP_MERGED" \
| curl -s -X POST \
    -H "Authorization: Bearer $LOCAL_TOKEN" \
    -H "Content-Type: application/json" \
    --data @- \
    "$LOCAL_URL/schema/diff" > "$TMP_DIFF"

jq -c '.data' < "$TMP_DIFF" \
| curl -s -X POST \
    -H "Authorization: Bearer $LOCAL_TOKEN" \
    -H "Content-Type: application/json" \
    --data @- \
    "$LOCAL_URL/schema/apply" > "$TMP_APPLY"

:

# ----------------------------
# 2️⃣ Export updated local schema → write schema.json
# ----------------------------
curl -s -X GET \
  -H "Authorization: Bearer $LOCAL_TOKEN" \
  "$LOCAL_URL/schema/snapshot" \
| jq '.data' > schema.json

if [ ! -s schema.json ]; then
  echo "❌ Failed to write schema.json."
  exit 1
fi

: