#!/bin/bash
set -euo pipefail

# ----------------------------
# Configuration
# ----------------------------
PROD_URL=${DIRECTUS_PROD_URL:-"https://directus-w8it.onrender.com"}
PROD_TOKEN=${DIRECTUS_PROD_ADMIN_TOKEN:-"peQKiHGzRp922iFIS0UNU678bNZY0Gay"}
LOCAL_URL=${DIRECTUS_LOCAL_URL:-"http://localhost:8055"}
LOCAL_TOKEN=${DIRECTUS_LOCAL_TOKEN:-"OwZdxXV6z403Wj7hhxbfhaiuMgaZtKoG"}

# ----------------------------
# 1️⃣ Merge prod + local-only collections → compute diff → apply
# ----------------------------
echo "📥 Fetching prod & local snapshots, merging local-only collections, applying diff..."

TMP_PROD=$(mktemp)
TMP_LOCAL=$(mktemp)
TMP_MERGED=$(mktemp)
cleanup() { rm -f "$TMP_PROD" "$TMP_LOCAL" "$TMP_MERGED"; }
trap cleanup EXIT

# Fetch production snapshot (.data)
curl -s -X GET \
  -H "Authorization: Bearer $PROD_TOKEN" \
  "$PROD_URL/schema/snapshot" \
| jq '.data' > "$TMP_PROD"

# Fetch local snapshot (.data)
curl -s -X GET \
  -H "Authorization: Bearer $LOCAL_TOKEN" \
  "$LOCAL_URL/schema/snapshot" \
| jq '.data' > "$TMP_LOCAL"

# Merge: start from prod, add local-only collections/fields/relations
jq -n \
  --slurpfile P "$TMP_PROD" \
  --slurpfile L "$TMP_LOCAL" \
  '
  $P[0] as $prod | $L[0] as $local |
  ($local.collections // [] | map(.collection)) as $localNames |
  ($prod.collections  // [] | map(.collection)) as $prodNames |
  ($localNames - $prodNames) as $localOnly |

  def onlyLocal(arr):
    (arr // [])
    | map(select((.collection // null) as $c | ($c != null) and (($localOnly | index($c)) != null)));

  {
    collections:  (($prod.collections  // []) + onlyLocal($local.collections)),
    fields:       (($prod.fields       // []) + onlyLocal($local.fields)),
    relations:    (($prod.relations    // []) + onlyLocal($local.relations)),
    permissions:  ($prod.permissions   // []),
    presets:      ($prod.presets       // []),
    dashboards:   ($prod.dashboards    // []),
    panels:       ($prod.panels        // []),
    flows:        ($prod.flows         // []),
    operations:   ($prod.operations    // []),
    webhooks:     ($prod.webhooks      // []),
    translations: ($prod.translations  // [])
  }
  ' > "$TMP_MERGED"

if [ ${DEBUG:-0} = 1 ]; then
  echo "Saved merged snapshot preview: $TMP_MERGED"
fi

cat "$TMP_MERGED" \
| curl -s -X POST \
    -H "Authorization: Bearer $LOCAL_TOKEN" \
    -H "Content-Type: application/json" \
    --data @- \
    "$LOCAL_URL/schema/diff" \
| tee ${DEBUG:+diff_raw.json} \
| jq -c '.data' \
| tee ${DEBUG:+diff_filtered.json} \
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
