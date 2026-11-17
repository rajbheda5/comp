#!/usr/bin/env bash
# Creates the AWS resources for the single-instance Comp deployment.
# Run on your workstation with the AWS CLI logged in (`aws login` / SSO).
#
#   - Lightsail instance (Ubuntu 24.04, 4 GB / 2 vCPU bundle, ~$24/month)
#   - Lightsail static IP (free while attached) + firewall: 22, 80, 443, 5432
#   - 5 private, encrypted S3 buckets: 4 for app files, 1 for DB backups
#   - IAM user "<name>-app"    : read/write on the 4 file buckets only
#   - IAM user "<name>-backup" : put-only on the backups bucket
#
# Writes deploy/aws/provision-output.env (gitignored) with bucket names,
# access keys and the static IP; feed it to scripts/init-env.sh.
#
# Safe to re-run: existing resources are left as they are.
#
# Settings (environment variables):
#   AWS_REGION   default: us-east-2
#   NAME         default: comp            (prefix for every resource)
#   BUNDLE_ID    default: medium_3_0      (4 GB RAM, 2 vCPU, 80 GB SSD)
#   SSH_CIDR     default: 0.0.0.0/0       (restrict to your IP, e.g. 203.0.113.7/32)

set -euo pipefail

# us-east-2 (Ohio): lowest-tier pricing (same as N. Virginia), historically
# fewer large outages than us-east-1, ~10 ms from Trigger.dev's US workers.
REGION="${AWS_REGION:-us-east-2}"
NAME="${NAME:-comp}"
BUNDLE_ID="${BUNDLE_ID:-medium_3_0}"
BLUEPRINT_ID="${BLUEPRINT_ID:-ubuntu_24_04}"
AZ="${AZ:-${REGION}a}"
SSH_CIDR="${SSH_CIDR:-0.0.0.0/0}"

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../provision-output.env"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

log() { printf '\n==> %s\n' "$*"; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

BUNDLE_INFO="$(aws lightsail get-bundles \
  --query "bundles[?bundleId=='${BUNDLE_ID}'] | [0].[price, ramSizeInGb, cpuCount, diskSizeInGb]" \
  --output text)"
if [ -z "$BUNDLE_INFO" ] || [ "$BUNDLE_INFO" = "None" ]; then
  echo "Unknown Lightsail bundle '$BUNDLE_ID' in $REGION. List them with: aws lightsail get-bundles" >&2
  exit 1
fi
read -r PRICE RAM CPU DISK <<<"$BUNDLE_INFO"

PREFIX="${NAME}-${ACCOUNT_ID}-${REGION}"
FILES_BUCKET="${PREFIX}-attachments"
QUESTIONNAIRE_BUCKET="${PREFIX}-questionnaire"
KB_BUCKET="${PREFIX}-knowledge-base"
ASSETS_BUCKET="${PREFIX}-org-assets"
BACKUP_BUCKET="${PREFIX}-backups"
APP_BUCKETS=("$FILES_BUCKET" "$QUESTIONNAIRE_BUCKET" "$KB_BUCKET" "$ASSETS_BUCKET")

cat <<EOF
About to create in AWS account $ACCOUNT_ID, region $REGION:
  Lightsail instance '$NAME'  bundle $BUNDLE_ID: \$$PRICE/month, ${RAM} GB RAM, $CPU vCPU, ${DISK} GB SSD
  Static IP '${NAME}-ip', open ports 22 ($SSH_CIDR), 80, 443, 5432
  S3 buckets: ${APP_BUCKETS[*]} $BACKUP_BUCKET
  IAM users: ${NAME}-app, ${NAME}-backup (one access key each)
EOF
if [ "${YES:-}" != "1" ]; then
  read -r -p "Proceed? [y/N] " answer
  [ "$answer" = "y" ] || [ "$answer" = "Y" ] || { echo "Aborted."; exit 1; }
fi

# --- Lightsail instance ------------------------------------------------------
log "Lightsail instance"
if aws lightsail get-instance --instance-name "$NAME" >/dev/null 2>&1; then
  echo "Instance $NAME already exists."
else
  aws lightsail create-instances \
    --instance-names "$NAME" \
    --availability-zone "$AZ" \
    --blueprint-id "$BLUEPRINT_ID" \
    --bundle-id "$BUNDLE_ID" \
    --user-data "file://$HERE/server-setup.sh" \
    --tags "key=app,value=$NAME" >/dev/null
  echo "Created instance $NAME."
fi

printf 'Waiting for the instance to be running'
for _ in $(seq 1 60); do
  state="$(aws lightsail get-instance-state --instance-name "$NAME" --query state.name --output text)"
  [ "$state" = "running" ] && break
  printf '.'; sleep 5
done
echo " $state"
[ "$state" = "running" ] || { echo "Instance did not reach 'running'." >&2; exit 1; }

log "Static IP"
if ! aws lightsail get-static-ip --static-ip-name "${NAME}-ip" >/dev/null 2>&1; then
  aws lightsail allocate-static-ip --static-ip-name "${NAME}-ip" >/dev/null
fi
attached_to="$(aws lightsail get-static-ip --static-ip-name "${NAME}-ip" --query staticIp.attachedTo --output text)"
if [ "$attached_to" != "$NAME" ]; then
  aws lightsail attach-static-ip --static-ip-name "${NAME}-ip" --instance-name "$NAME" >/dev/null
fi
STATIC_IP="$(aws lightsail get-static-ip --static-ip-name "${NAME}-ip" --query staticIp.ipAddress --output text)"
echo "Static IP: $STATIC_IP"

log "Firewall"
# 5432 is open to the internet because Trigger.dev Cloud task runners connect
# to Postgres and have no fixed egress IPs. Postgres only accepts TLS + SCRAM.
aws lightsail put-instance-public-ports --instance-name "$NAME" --port-infos \
  "[{\"fromPort\":22,\"toPort\":22,\"protocol\":\"tcp\",\"cidrs\":[\"$SSH_CIDR\"]},
    {\"fromPort\":80,\"toPort\":80,\"protocol\":\"tcp\",\"cidrs\":[\"0.0.0.0/0\"],\"ipv6Cidrs\":[\"::/0\"]},
    {\"fromPort\":443,\"toPort\":443,\"protocol\":\"tcp\",\"cidrs\":[\"0.0.0.0/0\"],\"ipv6Cidrs\":[\"::/0\"]},
    {\"fromPort\":5432,\"toPort\":5432,\"protocol\":\"tcp\",\"cidrs\":[\"0.0.0.0/0\"],\"ipv6Cidrs\":[\"::/0\"]}]" >/dev/null
echo "Ports 22, 80, 443, 5432 open."

# --- S3 ----------------------------------------------------------------------
create_bucket() {
  local bucket="$1"
  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    echo "Bucket $bucket already exists."
  else
    if [ "$REGION" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "$bucket" >/dev/null
    else
      aws s3api create-bucket --bucket "$bucket" \
        --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
    fi
    echo "Created bucket $bucket."
  fi
  aws s3api put-public-access-block --bucket "$bucket" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$bucket" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
}

log "S3 buckets"
for b in "${APP_BUCKETS[@]}" "$BACKUP_BUCKET"; do create_bucket "$b"; done

# Backups: versioned (an overwrite can't destroy a dump), kept 30 days.
aws s3api put-bucket-versioning --bucket "$BACKUP_BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-lifecycle-configuration --bucket "$BACKUP_BUCKET" --lifecycle-configuration \
  '{"Rules":[{"ID":"expire-old-dumps","Status":"Enabled","Filter":{"Prefix":""},
     "Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":7},
     "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":2}}]}'

# --- IAM ---------------------------------------------------------------------
ensure_user_with_key() {
  local user="$1" policy_json="$2" prefix="$3"
  if ! aws iam get-user --user-name "$user" >/dev/null 2>&1; then
    aws iam create-user --user-name "$user" --tags "Key=app,Value=$NAME" >/dev/null
    echo "Created IAM user $user."
  fi
  aws iam put-user-policy --user-name "$user" --policy-name "${user}-s3" --policy-document "$policy_json"

  if grep -q "^${prefix}_ACCESS_KEY_ID=" "$OUT" 2>/dev/null; then
    echo "Access key for $user already recorded in provision-output.env."
    return
  fi
  local existing
  existing="$(aws iam list-access-keys --user-name "$user" --query 'length(AccessKeyMetadata)' --output text)"
  if [ "$existing" != "0" ]; then
    echo "$user already has an access key that isn't in provision-output.env." >&2
    echo "Delete it in the IAM console (or create one manually) and re-run." >&2
    exit 1
  fi
  local key
  key="$(aws iam create-access-key --user-name "$user" \
    --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)"
  read -r kid secret <<<"$key"
  {
    echo "${prefix}_ACCESS_KEY_ID=$kid"
    echo "${prefix}_SECRET_ACCESS_KEY=$secret"
  } >>"$OUT"
  echo "Created access key for $user."
}

bucket_arns() {
  local out="" b
  for b in "$@"; do out+="\"arn:aws:s3:::$b\","; done
  echo "${out%,}"
}
object_arns() {
  local out="" b
  for b in "$@"; do out+="\"arn:aws:s3:::$b/*\","; done
  echo "${out%,}"
}

APP_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[
  {\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\",\"s3:GetBucketLocation\"],\"Resource\":[$(bucket_arns "${APP_BUCKETS[@]}")]},
  {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\"],\"Resource\":[$(object_arns "${APP_BUCKETS[@]}")]}]}"
BACKUP_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[
  {\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\"],\"Resource\":[$(object_arns "$BACKUP_BUCKET")]}]}"

touch "$OUT"
chmod 600 "$OUT"

log "IAM users"
ensure_user_with_key "${NAME}-app" "$APP_POLICY" "APP_AWS"
ensure_user_with_key "${NAME}-backup" "$BACKUP_POLICY" "BACKUP_AWS"

# --- Output ------------------------------------------------------------------
upsert() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$OUT"; then
    K="$key" V="$value" awk 'BEGIN{k=ENVIRON["K"]; v=ENVIRON["V"]}
      index($0, k"=")==1 {print k"="v; next} {print}' "$OUT" >"$OUT.tmp" && mv "$OUT.tmp" "$OUT"
  else
    echo "${key}=${value}" >>"$OUT"
  fi
}
upsert STATIC_IP "$STATIC_IP"
upsert APP_AWS_REGION "$REGION"
upsert APP_AWS_BUCKET_NAME "$FILES_BUCKET"
upsert APP_AWS_QUESTIONNAIRE_UPLOAD_BUCKET "$QUESTIONNAIRE_BUCKET"
upsert APP_AWS_KNOWLEDGE_BASE_BUCKET "$KB_BUCKET"
upsert APP_AWS_ORG_ASSETS_BUCKET "$ASSETS_BUCKET"
upsert BACKUP_BUCKET "$BACKUP_BUCKET"
upsert BACKUP_AWS_REGION "$REGION"
chmod 600 "$OUT"

KEY_FILE="$HOME/.ssh/lightsail-${REGION}.pem"
if [ ! -f "$KEY_FILE" ]; then
  mkdir -p "$HOME/.ssh"
  aws lightsail download-default-key-pair --query privateKeyBase64 --output text >"$KEY_FILE"
  chmod 600 "$KEY_FILE"
fi

cat <<EOF

Done. Static IP: $STATIC_IP
Outputs (with secrets) written to: $OUT

Next:
  1. Create DNS A records -> $STATIC_IP for your app, portal, api and db hostnames.
  2. ssh -i $KEY_FILE ubuntu@$STATIC_IP
     (first boot installs Docker; check with: cloud-init status --wait)
  3. Follow deploy/aws/README.md from "Configure the server".
EOF
