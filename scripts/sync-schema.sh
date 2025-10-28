#!/bin/bash
set -euo pipefail

# ----------------------------
# Configuration
# ----------------------------
# Load .env if present
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

# Validate required vars
for v in PROD_URL PROD_TOKEN LOCAL_TOKEN; do
  if [ -z "${!v}" ]; then
    echo "❌ Missing $v. Please set it in .env or environment."
    exit 1
  fi
done

# ----------------------------
# 1️⃣ Merge prod + local-only collections → compute diff → apply
# ----------------------------
echo "📥 Fetching prod & local snapshots, merging local-only collections, applying diff..."

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
    collections:  (($P[0].collections  // []) + onlyLocal($L[0].collections)),
    fields:       (($P[0].fields       // []) + onlyLocal($L[0].fields)),
    relations:    (($P[0].relations    // []) + onlyLocal($L[0].relations)),
    permissions:  ($P[0].permissions   // []),
    presets:      ($P[0].presets       // []),
    dashboards:   ($P[0].dashboards    // []),
    panels:       ($P[0].panels        // []),
    flows:        ($P[0].flows         // []),
    operations:   ($P[0].operations    // []),
    webhooks:     ($P[0].webhooks      // []),
    translations: ($P[0].translations  // [])
  }
  ' > "$TMP_MERGED"

# Compute diff and apply
cat "$TMP_MERGED" \
| curl -s -X POST \
    -H "Authorization: Bearer $LOCAL_TOKEN" \
    -H "Content-Type: application/json" \
    --data @- \
    "$LOCAL_URL/schema/diff" \
| jq -c '.data' \
| curl -s -X POST \
    -H "Authorization: Bearer $LOCAL_TOKEN" \
    -H "Content-Type: application/json" \
    --data @- \
    "$LOCAL_URL/schema/apply" > /dev/null

echo "✅ Local Directus schema updated (prod + local-only preserved)."

# ----------------------------
# 2️⃣ Export updated local schema → write schema.json
# ----------------------------
echo "📦 Exporting updated local schema to schema.json..."
curl -s -X GET \
  -H "Authorization: Bearer $LOCAL_TOKEN" \
  "$LOCAL_URL/schema/snapshot" \
| jq '.data' > schema.json

if [ ! -s schema.json ]; then
  echo "❌ Failed to write schema.json."
  exit 1
fi

echo "✅ schema.json updated with current local snapshot."
echo "🎉 Done! You can now commit and push schema.json."