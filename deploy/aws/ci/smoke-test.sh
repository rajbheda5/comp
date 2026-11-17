#!/usr/bin/env bash
# End-to-end smoke test of the single-box stack, run on a GitHub-hosted runner.
# Exercises the real images and the real bootstrap/deploy scripts:
#   bootstrap.sh (Caddy cert → Postgres TLS → migrate → seed → apps)
#   HTTPS health of api/app/portal through Caddy
#   Postgres: TLS-only, verify-full over the DB hostname, plaintext refused
#   Upstash-compatible Redis REST endpoint
#   Login: email OTP → session cookie scoped to the parent domain → app accepts it
#   deploy.sh re-run (idempotent migrate + seed)
#   pg_dump works; memory per container (→ which Lightsail bundle fits)
#
# Requires: IMAGE_PREFIX, IMAGE_TAG (images already pushed), docker login done.

set -euo pipefail

cd "$(dirname "$0")/.."
DIR="$(pwd)"
D=comp.test
export COMPOSE_FILE="docker-compose.yml:ci/docker-compose.ci.yml"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

pass() { echo "✅ $*"; echo "- ✅ $*" >>"$SUMMARY"; }
fail() { echo "❌ $*" >&2; echo "- ❌ $*" >>"$SUMMARY"; exit 1; }

set_kv() {
  local file="$1" key="$2" value="$3"
  K="$key" V="$value" awk 'BEGIN{k=ENVIRON["K"]; v=ENVIRON["V"]}
    index($0, k"=")==1 {print k"="v; found=1; next} {print}
    END{if(!found) print k"="v}' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
}

echo "## Comp AWS stack smoke test" >>"$SUMMARY"

# --- Throwaway root CA (stands in for Let's Encrypt) --------------------------
mkdir -p data/ci-ca
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
  -subj "/CN=Comp CI Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout data/ci-ca/root.key -out data/ci-ca/root.crt 2>/dev/null
chmod 644 data/ci-ca/root.crt

# --- Env files ----------------------------------------------------------------
rm -f .env comp.env
scripts/init-env.sh /dev/null >/dev/null
for kv in \
  "APP_DOMAIN=app.$D" "PORTAL_DOMAIN=portal.$D" "API_DOMAIN=api.$D" "DB_DOMAIN=db.$D" \
  "COOKIE_DOMAIN=.$D" "ACME_EMAIL=ci@$D" \
  "IMAGE_PREFIX=$IMAGE_PREFIX" "IMAGE_TAG=$IMAGE_TAG" \
  "TRIGGER_APP_SECRET_KEY=tr_prod_ci_dummy_app" "TRIGGER_API_SECRET_KEY=tr_prod_ci_dummy_api"; do
  set_kv .env "${kv%%=*}" "${kv#*=}"
done
for kv in \
  "RESEND_API_KEY=re_ci_dummy" \
  "APP_AWS_REGION=us-east-2" "APP_AWS_ACCESS_KEY_ID=AKIACIDUMMY" "APP_AWS_SECRET_ACCESS_KEY=ci-dummy" \
  "APP_AWS_BUCKET_NAME=ci-attachments" "APP_AWS_QUESTIONNAIRE_UPLOAD_BUCKET=ci-questionnaire" \
  "APP_AWS_KNOWLEDGE_BASE_BUCKET=ci-kb" "APP_AWS_ORG_ASSETS_BUCKET=ci-assets"; do
  set_kv comp.env "${kv%%=*}" "${kv#*=}"
done
env_get() { grep -E "^$1=" .env | tail -1 | cut -d= -f2-; }
PG_PASSWORD="$(env_get POSTGRES_PASSWORD)"

# --- Bootstrap (the real first-run script) -------------------------------------
start=$(date +%s)
scripts/bootstrap.sh
pass "bootstrap.sh completed in $(( $(date +%s) - start ))s (Caddy cert → Postgres TLS → migrate → seed → apps)"

CURL=(curl -sS --max-time 30 --cacert "$DIR/data/ci-ca/root.crt"
  --resolve "app.$D:443:127.0.0.1" --resolve "portal.$D:443:127.0.0.1" --resolve "api.$D:443:127.0.0.1")

wait_http() {
  local url="$1" want="$2" code=""
  for _ in $(seq 1 60); do
    code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
    if [[ " $want " == *" $code "* ]]; then echo "$code"; return 0; fi
    sleep 5
  done
  echo "$code"; return 1
}

code=$(wait_http "https://api.$D/v1/health" "200") || fail "API health over HTTPS (last status $code)"
pass "API https://api.$D/v1/health → $code"
code=$(wait_http "https://app.$D/api/health" "200") || fail "App health over HTTPS (last status $code)"
pass "App https://app.$D/api/health → $code"
code=$(wait_http "https://portal.$D/" "200 302 303 307 308") || fail "Portal over HTTPS (last status $code)"
pass "Portal https://portal.$D/ → $code"

# --- Postgres: TLS-only, verifiable by hostname (what Trigger.dev Cloud does) --
PSQL=(docker run --rm --network host -v "$DIR/data/ci-ca:/ca:ro" postgres:17-alpine psql)
if "${PSQL[@]}" "host=db.$D hostaddr=127.0.0.1 port=5432 user=comp dbname=comp password=$PG_PASSWORD sslmode=verify-full sslrootcert=/ca/root.crt" -tAc 'select 1' | grep -qx 1; then
  pass "Postgres accepts TLS with verify-full against db.$D"
else
  fail "Postgres verify-full TLS connection"
fi
if "${PSQL[@]}" "host=127.0.0.1 port=5432 user=comp dbname=comp password=$PG_PASSWORD sslmode=disable" -tAc 'select 1' >/dev/null 2>&1; then
  fail "Postgres accepted a plaintext connection"
else
  pass "Postgres refuses plaintext connections"
fi

TABLES=$(docker compose exec -T postgres psql -U comp -d comp -tAc "select count(*) from information_schema.tables where table_schema='public'")
FRAMEWORKS=$(docker compose exec -T postgres psql -U comp -d comp -tAc 'select count(*) from "FrameworkEditorFramework"')
[ "$TABLES" -gt 50 ] || fail "only $TABLES tables after migrate"
[ "$FRAMEWORKS" -gt 0 ] || fail "no frameworks after seed"
pass "Database migrated ($TABLES tables) and seeded ($FRAMEWORKS frameworks)"

# --- Redis via the Upstash-compatible REST proxy -------------------------------
REDIS_TOKEN="$(env_get REDIS_HTTP_TOKEN)"
out=$(docker compose exec -T api node -e "
  const h={Authorization:'Bearer ' + process.argv[1]};
  fetch('http://redis-http:80/set/smoke/ok',{headers:h})
    .then(()=>fetch('http://redis-http:80/get/smoke',{headers:h}))
    .then(r=>r.json()).then(j=>console.log(j.result))
    .catch(e=>{console.error(e);process.exit(1)})" "$REDIS_TOKEN")
[ "$out" = ok ] || fail "Redis REST round trip (got '$out')"
pass "Upstash-compatible Redis REST round trip"

# --- Login: email OTP → cross-subdomain session cookie → app accepts it ------
EMAIL="smoke@$D"
"${CURL[@]}" -o /dev/null -X POST "https://api.$D/api/auth/email-otp/send-verification-otp" \
  -H 'Content-Type: application/json' -H "Origin: https://app.$D" \
  -d "{\"email\":\"$EMAIL\",\"type\":\"sign-in\"}" || true
OTP=$(docker compose exec -T postgres psql -U comp -d comp -tAc \
  "select split_part(value, ':', 1) from \"Verification\" where identifier = 'sign-in-otp-$EMAIL' order by \"createdAt\" desc limit 1")
[ -n "$OTP" ] || fail "no sign-in OTP stored for $EMAIL"

HEADERS="$(mktemp)"
status=$("${CURL[@]}" -D "$HEADERS" -o /dev/null -w '%{http_code}' -X POST "https://api.$D/api/auth/sign-in/email-otp" \
  -H 'Content-Type: application/json' -H "Origin: https://app.$D" \
  -d "{\"email\":\"$EMAIL\",\"otp\":\"$OTP\"}")
[ "$status" = 200 ] || { cat "$HEADERS"; fail "OTP sign-in returned $status"; }
COOKIE_LINE=$(grep -i '^set-cookie: __Secure-better-auth.session_token=' "$HEADERS" || true)
[ -n "$COOKIE_LINE" ] || { cat "$HEADERS"; fail "no __Secure-better-auth.session_token cookie"; }
echo "$COOKIE_LINE" | grep -qi "domain=\.\?$D" || fail "session cookie not scoped to .$D: $COOKIE_LINE"
pass "OTP sign-in sets __Secure-better-auth.session_token for .$D"

TOKEN=$(echo "$COOKIE_LINE" | sed -E 's/^[Ss]et-[Cc]ookie: __Secure-better-auth\.session_token=([^;]*).*/\1/' | tr -d '\r')
SESSION_EMAIL=$("${CURL[@]}" -H "Cookie: __Secure-better-auth.session_token=$TOKEN" -H "Origin: https://app.$D" \
  "https://api.$D/api/auth/get-session" | sed -nE 's/.*"email":"([^"]+)".*/\1/p')
[ "$SESSION_EMAIL" = "$EMAIL" ] || fail "API get-session with cookie returned '$SESSION_EMAIL'"
pass "API recognises the session cookie"

anon=$("${CURL[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' "https://app.$D/")
authed=$("${CURL[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' \
  -H "Cookie: __Secure-better-auth.session_token=$TOKEN" "https://app.$D/")
echo "app / anonymous: $anon | signed in: $authed"
[[ "$anon" == *"/auth"* ]] || fail "anonymous app request should redirect to /auth (got $anon)"
[[ "$authed" != *"/auth"* ]] || fail "signed-in app request still redirected to /auth ($authed)"
pass "App accepts the cross-subdomain session (anonymous → /auth, signed in → ${authed})"

# --- Re-deploy path is idempotent ---------------------------------------------
scripts/deploy.sh >/dev/null
code=$(wait_http "https://api.$D/v1/health" "200") || fail "API unhealthy after deploy.sh"
code=$(wait_http "https://app.$D/api/health" "200") || fail "App unhealthy after deploy.sh"
pass "deploy.sh re-run (migrate + seed again) leaves the stack healthy"

# --- Backup dump ---------------------------------------------------------------
bytes=$(docker compose exec -T postgres pg_dump -U comp -d comp --format=custom | wc -c)
[ "$bytes" -gt 100000 ] || fail "pg_dump produced only $bytes bytes"
pass "pg_dump custom-format dump: $((bytes / 1024)) KiB"

# --- Memory: warm up, then measure ---------------------------------------------
for _ in $(seq 1 5); do
  "${CURL[@]}" -o /dev/null "https://app.$D/auth" || true
  "${CURL[@]}" -o /dev/null -H "Cookie: __Secure-better-auth.session_token=$TOKEN" "https://app.$D/" || true
  "${CURL[@]}" -o /dev/null "https://portal.$D/" || true
  "${CURL[@]}" -o /dev/null "https://api.$D/v1/health" || true
done
sleep 10
{
  echo
  echo "### Memory after warm-up"
  echo '| container | memory |'
  echo '|---|---|'
} >>"$SUMMARY"
total_mib=0
while read -r name usage; do
  value="${usage%%/*}"
  mib=$(awk -v v="$value" 'BEGIN{
    n=v; sub(/[A-Za-z]+$/,"",n); u=v; sub(/^[0-9.]+/,"",u);
    if(u=="GiB") n*=1024; else if(u=="KiB"||u=="kB") n/=1024; else if(u=="B") n/=1048576;
    printf "%.0f", n }')
  total_mib=$((total_mib + mib))
  echo "| $name | ${mib} MiB |" >>"$SUMMARY"
  echo "$name ${mib}MiB"
done < <(docker stats --no-stream --format '{{.Name}} {{.MemUsage}}')
echo "| **total** | **${total_mib} MiB** |" >>"$SUMMARY"
echo "TOTAL_MIB=$total_mib"
echo "total_mib=$total_mib" >>"${GITHUB_OUTPUT:-/dev/null}"
pass "Containers use ${total_mib} MiB in total after warm-up"
