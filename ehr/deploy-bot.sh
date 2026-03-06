#!/usr/bin/env bash
# Deploy and optionally execute the EHR importer bot via Medplum REST API.
#
# Usage:
#   ./deploy-bot.sh              # deploy only
#   ./deploy-bot.sh --run        # deploy and execute
#
# Requirements: curl, jq, npx (for tsc)
set -uo pipefail

# Helper: run curl and exit with the response body on HTTP error
curl_or_die() {
  local response http_code
  response=$(curl -sS -w '\n__HTTP_CODE__%{http_code}' "$@")
  http_code=$(echo "$response" | tail -1 | sed 's/__HTTP_CODE__//')
  response=$(echo "$response" | sed '$d')
  if [ "$http_code" -ge 400 ]; then
    echo "ERROR: HTTP $http_code" >&2
    echo "$response" | jq . >&2 2>/dev/null || echo "$response" >&2
    exit 1
  fi
  echo "$response"
}

MEDPLUM_BASE="http://localhost:8103"
EMAIL="admin@example.com"
PASSWORD="medplum_admin"
BOT_NAME="EHR Importer"
BOT_FILE="$(dirname "$0")/ehr-importer.bot.ts"

# ── 1. Authenticate ──────────────────────────────────────────────────────────
# PKCE 'plain' method: code_verifier == code_challenge (no crypto required)
CODE_VERIFIER="$(openssl rand -hex 32)"

echo "Logging in..."
LOGIN=$(curl_or_die -X POST "$MEDPLUM_BASE/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"scope\":\"openid\",\"codeChallenge\":\"$CODE_VERIFIER\",\"codeChallengeMethod\":\"plain\"}")

# If multiple projects exist, pick the first membership; otherwise code is returned directly
CODE=$(echo "$LOGIN" | jq -r '.code // empty')
if [ -z "$CODE" ]; then
  echo "Selecting profile..."
  LOGIN_ID=$(echo "$LOGIN" | jq -r '.login')
  MEMBERSHIP_ID=$(echo "$LOGIN" | jq -r '.memberships[0].id')
  PROFILE=$(curl_or_die -X POST "$MEDPLUM_BASE/auth/profile" \
    -H "Content-Type: application/json" \
    -d "{\"login\":\"$LOGIN_ID\",\"profile\":\"$MEMBERSHIP_ID\"}")
  CODE=$(echo "$PROFILE" | jq -r '.code')
fi

echo "Exchanging code for token..."
TOKEN_RESP=$(curl_or_die -X POST "$MEDPLUM_BASE/oauth2/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code&code=$CODE&code_verifier=$CODE_VERIFIER")

ACCESS_TOKEN=$(echo "$TOKEN_RESP" | jq -r '.access_token')
AUTH="Authorization: Bearer $ACCESS_TOKEN"
PROJECT_ID=$(echo "$TOKEN_RESP" | jq -r '.project.reference' | cut -d'/' -f2)

# ── 1b. Enable bots feature on the project (idempotent) ──────────────────────
echo "Enabling bots feature on project $PROJECT_ID..."
PROJECT=$(curl_or_die "$MEDPLUM_BASE/fhir/R4/Project/$PROJECT_ID" -H "$AUTH")
FEATURES=$(echo "$PROJECT" | jq -r '.features // []')
HAS_BOTS=$(echo "$FEATURES" | jq 'contains(["bots"])')
if [ "$HAS_BOTS" != "true" ]; then
  NEW_FEATURES=$(echo "$FEATURES" | jq '. + ["bots"]')
  curl_or_die -X PATCH "$MEDPLUM_BASE/fhir/R4/Project/$PROJECT_ID" \
    -H "$AUTH" -H "Content-Type: application/json-patch+json" \
    -d "[{\"op\":\"add\",\"path\":\"/features\",\"value\":$NEW_FEATURES}]" > /dev/null
  echo "Bots feature enabled."
else
  echo "Bots feature already enabled."
fi

# ── 2. Create or find the bot ────────────────────────────────────────────────
echo "Looking for existing bot '$BOT_NAME'..."
EXISTING=$(curl_or_die -G --data-urlencode "name=$BOT_NAME" "$MEDPLUM_BASE/fhir/R4/Bot" -H "$AUTH")
BOT_ID=$(echo "$EXISTING" | jq -r '.entry[0].resource.id // empty')

if [ -z "$BOT_ID" ]; then
  echo "Creating new bot..."
  BOT=$(curl_or_die -X POST "$MEDPLUM_BASE/fhir/R4/Bot" \
    -H "$AUTH" -H "Content-Type: application/fhir+json" \
    -d "{
      \"resourceType\": \"Bot\",
      \"name\": \"$BOT_NAME\",
      \"runtimeVersion\": \"vmcontext\",
      \"description\": \"Imports patients and clinical data from the remote EHR FHIR server\"
    }")
  BOT_ID=$(echo "$BOT" | jq -r '.id')
  echo "Created bot: $BOT_ID"
else
  echo "Found existing bot: $BOT_ID"
fi

# ── 3. Compile TypeScript → JavaScript ───────────────────────────────────────
echo "Compiling TypeScript..."
JS_TMP=$(mktemp /tmp/bot-XXXXXX.js)
# Use esbuild from the monorepo root (or fall back to npx)
ESBUILD="$(dirname "$0")/../../node_modules/.bin/esbuild"
if [ ! -x "$ESBUILD" ]; then ESBUILD="npx esbuild"; fi
$ESBUILD "$BOT_FILE" \
  --bundle=false \
  --platform=node \
  --format=cjs \
  --outfile="$JS_TMP"
# vmcontext defines `const exports = {}; const module = {exports};`
# esbuild replaces module.exports entirely via __toCommonJS, breaking the
# `exports` reference. This line re-syncs them so exports.handler is found.
echo 'if(typeof module!=="undefined"&&module.exports!==exports)Object.assign(exports,module.exports);' >> "$JS_TMP"
echo "Compiled to $JS_TMP"

# ── 4. Upload TypeScript source as Binary (for reference / editor) ────────────
echo "Uploading TypeScript source..."
TS_BINARY=$(curl_or_die -X POST "$MEDPLUM_BASE/fhir/R4/Binary" \
  -H "$AUTH" -H "Content-Type: text/typescript" \
  --data-binary "@$BOT_FILE")
TS_BINARY_ID=$(echo "$TS_BINARY" | jq -r '.id')

# ── 5. Deploy — pass compiled JS directly so server stores it as executableCode
echo "Deploying bot..."
JS_CODE=$(cat "$JS_TMP")
rm -f "$JS_TMP"
DEPLOY=$(curl_or_die -X POST "$MEDPLUM_BASE/fhir/R4/Bot/$BOT_ID/\$deploy" \
  -H "$AUTH" -H "Content-Type: application/fhir+json" \
  -d "{\"code\":$(echo "$JS_CODE" | jq -Rs .)}")
echo "Deploy response: $(echo "$DEPLOY" | jq -r '.issue[0].details.text // "ok"')"

# Attach TypeScript source to bot for future reference
curl_or_die -X PATCH "$MEDPLUM_BASE/fhir/R4/Bot/$BOT_ID" \
  -H "$AUTH" -H "Content-Type: application/json-patch+json" \
  -d "[{\"op\":\"add\",\"path\":\"/sourceCode\",\"value\":{\"contentType\":\"text/typescript\",\"url\":\"Binary/$TS_BINARY_ID\"}}]" \
  > /dev/null || true

echo ""
echo "Bot deployed successfully!"
echo "  ID:  $BOT_ID"
echo "  URL: http://localhost:3000/Bot/$BOT_ID/editor"

# ── 6. Optionally execute ─────────────────────────────────────────────────────
if [[ "${1:-}" == "--run" ]]; then
  echo ""
  echo "Executing bot..."
  RESULT=$(curl_or_die -X POST "$MEDPLUM_BASE/fhir/R4/Bot/$BOT_ID/\$execute" \
    -H "$AUTH" -H "Content-Type: application/fhir+json" \
    -d "{\"resourceType\":\"Parameters\"}")
  echo "Result: $RESULT"
fi
