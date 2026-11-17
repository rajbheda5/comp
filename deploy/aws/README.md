# Comp AI on AWS for about $25 a month

This folder runs the whole Comp AI stack on **one AWS Lightsail instance**, with background jobs on **Trigger.dev Cloud's free tier**. The job code is the same as upstream.

```
                        Lightsail 4 GB / 2 vCPU  ($24/mo, static IP included)
 users ──HTTPS──▶ Caddy ─┬─▶ app     (Next.js)   app.example.com
                         ├─▶ portal  (Next.js)   portal.example.com
                         └─▶ api     (NestJS)    api.example.com
                  Postgres 17  ◀── TLS :5432 ── db.example.com ◀── Trigger.dev Cloud task runners
                  Redis + redis-http (Upstash-compatible REST, private)
                         │
                         ├─▶ S3: attachments, questionnaires, knowledge base, org assets
                         └─▶ S3: nightly pg_dump backups (30-day retention)
```

## Monthly cost

| Item | Choice | Cost |
|---|---|---|
| Compute, disk, IPv4, 4 TB transfer | Lightsail `medium_3_0` (4 GB, 2 vCPU, 80 GB SSD) | **$24.00** |
| Database | Postgres in Docker on the instance | $0 |
| Redis | Redis + `serverless-redis-http` on the instance | $0 |
| File storage + backups | S3 (a few GB) | ~$0.10–0.50 |
| TLS certificates | Caddy + Let's Encrypt | $0 |
| Background jobs | Trigger.dev Cloud Free (2 projects, $5 usage credit each month) | $0 |
| Container images and CI | GHCR + GitHub Actions (free for public repos; this fork is public) | $0 |
| Email | Resend free tier (3,000/month, 100/day) | $0 |
| **Total** | | **≈ $24–25/month** |

AI usage is billed per call and comes on top:

- Vercel AI Gateway, for onboarding generation;
- OpenAI, for most features;
- Anthropic, for several API features.

Browserbase and Firecrawl are optional paid add-ons.

### Why Trigger.dev stays (and why it's Cloud, not self-hosted)

The job code is written against the Trigger.dev SDK in about 200 files. That includes 63 live-progress React hooks and 159 `metadata.set` progress updates. Swapping it for BullMQ, pg-boss or Hatchet would be a rewrite.

Trigger.dev is Apache-2.0 and can be self-hosted. Its own stack (webapp, Postgres, Redis, ClickHouse, registry, supervisor and workers) needs roughly 6–8 GB of RAM. That means the 16 GB, $84/month instance instead.

The Cloud free tier fits this deployment:

| Free-tier limit | What Comp uses |
|---|---|
| 10 schedules per project | app project: 6, API project: **10** (exactly at the limit) |
| 20 concurrent runs (prod) | plenty for one team |
| 10 concurrent realtime connections | the browser's live-progress widgets |
| $5 of compute each month | small-1x runs cost $0.12/hour; one org's daily jobs are cents |
| 1-day log retention | Hobby ($10/month) keeps 7 days if you need it |

If you outgrow it, Hobby costs $10/month. See "Upgrade paths" at the end.

### Trade-offs to accept

- **Postgres is reachable from the internet on port 5432.** Trigger.dev tasks query the database directly and have no fixed egress IPs, so it can't be restricted by source address. It is protected as follows:
  - Only TLS connections are accepted; `pg_hba.conf` has no plain `host` lines.
  - Logins use SCRAM with a 64-character random password.
  - The certificate is a real Let's Encrypt certificate, so clients verify it.
- **One machine.** There's no redundancy. Recovery means a new instance plus the latest S3 dump.
  - At most a day of data can be lost (backups run nightly).
  - A Lightsail snapshot before upgrades is a cheap extra safety net (about $0.05/GB-month).
- **2 vCPU burstable.** That's fine for a team using it during the day. AI-heavy onboarding runs on Trigger.dev, not on this box.

## Changes made to upstream code

Kept small so the fork stays easy to merge with upstream:

1. [`apps/api/src/auth/cookie-domain.ts`](../../apps/api/src/auth/cookie-domain.ts) adds `AUTH_COOKIE_DOMAIN`.
   - Upstream hardcodes the session-cookie domain to `.trycomp.ai`.
   - On any other domain, the login cookie stays on `api.` and the app's auth check never sees it.
2. [`Dockerfile`](../../Dockerfile) now passes the build-time `NEXT_PUBLIC_*` values upstream left out.
   - App: `SELF_HOSTED` (skips the payment wall), `APP_URL`, `APP_ENV`.
   - Portal: `API_URL`. Without it, the portal's auth client calls `localhost:3333`.
3. [`Dockerfile.migrator`](./Dockerfile.migrator) replaces the root `migrator` target.
   - The old target pins `@trycompai/db@^1.3.4` from npm.
   - It also runs a `seed.js` that no longer exists.

## Setup

### 0. Before you start

- A domain where you can add DNS records. The examples use `app.`, `portal.`, `api.` and `db.` under `example.com`.
- The AWS CLI, logged in. Run `aws login` if `aws sts get-caller-identity` says the session expired.
- Accounts on [Trigger.dev](https://cloud.trigger.dev) and [Resend](https://resend.com) (free).
- AI keys:
  - an **OpenAI** key;
  - a **Vercel AI Gateway** key (`AI_GATEWAY_API_KEY`). Onboarding uses it to generate your policies, risks and vendors.
  - an **Anthropic** key is recommended.

  The API boots without any of them, but those features fail.

### 1. Turn off upstream's workflows in your fork

Upstream's workflows target paid WarpBuild runners, release to npm and post to Discord. In your fork they would just queue or fail.

1. Enable Actions on the fork in GitHub → Actions.
2. Disable everything except `aws-deploy.yml`:

```bash
for wf in $(gh workflow list -R <you>/comp --all --json path -q '.[].path' | grep -v aws-deploy.yml); do
  gh workflow disable "$(basename "$wf")" -R <you>/comp
done
```

### 2. Trigger.dev projects

1. Create an organization and two projects at cloud.trigger.dev, e.g. `comp-app` and `comp-api`.
2. Note each **project ref** (`proj_…`).
3. Note each project's **Production secret key** (`tr_prod_…`).
4. Create a **personal access token** (`tr_pat_…`) for CI.

### 3. Provision AWS

Pick the region first. Every database query from a Trigger.dev task crosses the internet to this box, and task runs are billed per second. So put Lightsail in the AWS region closest to where your Trigger.dev projects run: check the project's **Regions** page, which is usually US East. Lightsail prices are the same in US and most EU regions.

```bash
AWS_REGION=us-east-1 SSH_CIDR=<your-ip>/32 deploy/aws/scripts/provision-aws.sh   # asks for confirmation
```

The script:

- creates the instance, static IP, firewall, five S3 buckets and two least-privilege IAM users;
- writes their details to `deploy/aws/provision-output.env` (gitignored, mode 600);
- saves the SSH key to `~/.ssh/lightsail-<region>.pem`.

### 4. DNS

Create **A records** for `app`, `portal`, `api` and `db` that point at the static IP the script printed.

### 5. Configure the server

```bash
scp -i ~/.ssh/lightsail-eu-west-1.pem deploy/aws/provision-output.env ubuntu@<ip>:/tmp/
ssh -i ~/.ssh/lightsail-eu-west-1.pem ubuntu@<ip>
cloud-init status --wait                     # first-boot Docker install

git clone --filter=blob:none --sparse https://github.com/<you>/comp.git /opt/comp
cd /opt/comp && git sparse-checkout set deploy/aws
cd deploy/aws
scripts/init-env.sh /tmp/provision-output.env && rm /tmp/provision-output.env
nano .env        # domains, ACME_EMAIL, IMAGE_PREFIX=ghcr.io/<you>, TRIGGER_APP/API_SECRET_KEY
nano comp.env    # RESEND_*, AI_GATEWAY_API_KEY, OPENAI_API_KEY, ANTHROPIC_API_KEY, optional keys
```

GHCR images are private by default. Log in once with a GitHub token that has only the `read:packages` scope:

```bash
echo <token> | docker login ghcr.io -u <you> --password-stdin
```

### 6. Trigger.dev environment variables

Tasks run on Trigger.dev's machines and need the same secrets. On the server:

```bash
scripts/trigger-env.sh app > /tmp/app.env   # import into comp-app → Production
scripts/trigger-env.sh api > /tmp/api.env   # import into comp-api → Production
# Dashboard → Environment Variables → Production → Import .env file. Then:
rm /tmp/app.env /tmp/api.env
```

### 7. First build and deploy

1. In the fork's **Settings → Secrets and variables → Actions**, set:
   - **Variables:** `APP_DOMAIN`, `PORTAL_DOMAIN`, `API_DOMAIN`, `TRIGGER_APP_PROJECT_REF`, `TRIGGER_API_PROJECT_REF`, `LIGHTSAIL_HOST`
   - **Secrets:** `TRIGGER_ACCESS_TOKEN`, `LIGHTSAIL_SSH_KEY` (contents of the `.pem`)
   - **Optional secret:** `LIGHTSAIL_KNOWN_HOSTS` (output of `ssh-keyscan <ip>`)
2. Run **Actions → AWS deploy → Run workflow** with **"Roll out on the Lightsail server" unticked**. This builds the four images (about 20–30 minutes the first time) and deploys both Trigger.dev projects.
3. On the server, start everything for the first time:

```bash
cd /opt/comp/deploy/aws && scripts/bootstrap.sh
```

The bootstrap script:

1. starts Caddy and waits for the database certificate;
2. starts Postgres and Redis;
3. runs migrations and the framework seed;
4. starts app, portal and API;
5. installs the daily certificate-sync and nightly backup cron jobs.

Open `https://app.<your-domain>`, sign in with an email magic link, and create your organization. Self-hosted mode auto-approves it.

## Day-to-day

| Task | Command |
|---|---|
| Release | Run the **AWS deploy** workflow (builds, deploys tasks, then `scripts/deploy.sh <sha>` on the box) |
| Roll back | On the server: `scripts/deploy.sh <previous-sha>` |
| Logs | `docker compose logs -f app api portal` |
| Status and memory | `docker compose ps` / `docker stats --no-stream` |
| Manual backup | `scripts/backup-db.sh` (cron runs it at 03:17 UTC) |
| Restore | See the header of `scripts/backup-db.sh` |
| Certificates | Caddy renews them; `scripts/sync-db-cert.sh` (04:40 UTC daily) hands the DB cert to Postgres |
| Pull upstream changes | `git fetch upstream && git merge upstream/main`, then release |

## Verification status

| Status | What |
|---|---|
| Checked | Compose config renders with the right per-service URLs and keys, and the database alias is set. |
| Checked | Scripts pass a syntax check. `init-env.sh` generates secrets and merges provisioning output. |
| Checked | The cookie-domain unit tests pass. |
| Checked | The migrator image's install and Prisma-generate steps build. |
| Not yet run | Containers: migrate and seed against TLS-only Postgres, the three apps booting, and whether everything fits in 4 GB. |

If the 4 GB box runs out of memory, re-run provisioning on a fresh instance with `BUNDLE_ID=large_3_0` (8 GB, $44/month).

## Upgrade paths

| When | Change | New cost |
|---|---|---|
| Free task credit or 10-schedule cap hit | Trigger.dev Hobby | +$10 |
| Box is memory-bound | Lightsail 8 GB (`large_3_0`) | $44 |
| Want no third-party job runner and a private DB | Lightsail 16 GB plus self-hosted Trigger.dev v4.7.7 (match the SDK). Also needs `baseURL` passed through in `apps/app/src/components/trigger-provider.tsx`, so the browser's realtime hooks call your instance instead of `api.trigger.dev`. | $84 |
| Need managed database / HA | RDS Postgres + ECS Fargate + ALB | ~$150+ |
