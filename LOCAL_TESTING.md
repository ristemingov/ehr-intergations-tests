# Local Testing Guide

This guide gets you a full EHR integration stack running locally: a Medplum FHIR server, the Medplum app, a simulated remote EHR (Microsoft FHIR Server on Azure SQL Edge), and a bot that imports data from the EHR into Medplum.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  docker-compose.ehr-stack.yml                        │
│                                                      │
│  medplum-app   (localhost:3000)                      │
│  medplum-server (localhost:8103)  ←── EHR Importer Bot
│  postgres      (localhost:5432)                      │
│  redis         (localhost:6379)                      │
│                                                      │
│  ehr           (localhost:8081)  ← Microsoft FHIR R4 │
│  ehr-sql       (internal)        ← Azure SQL Edge    │
└──────────────────────────────────────────────────────┘
```

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) with Docker Compose
- `curl`, `jq`, `openssl` (for the bot deploy script)
- Node.js + `npx` (for TypeScript compilation in the bot deploy script)
- Python 3.11+ with [`uv`](https://github.com/astral-sh/uv) (for seeding the EHR)

## Step 1 — Start the stack

From the repo root:

```bash
docker compose -f docker-compose.ehr-stack.yml up -d
```

> **Note:** The `ehr` service builds the Microsoft FHIR Server from source — this takes **10–20 minutes** on the first run. Subsequent starts use the cached image.

Wait until all services are healthy:

```bash
docker compose -f docker-compose.ehr-stack.yml ps
```

Expected healthy services: `postgres`, `redis`, `medplum-server`, `medplum-app`, `ehr-sql`, `ehr`.

Verify endpoints:

| Service | URL | Expected response |
|---|---|---|
| Medplum server | http://localhost:8103/healthcheck | `{"ok":true}` |
| Medplum app | http://localhost:3000 | HTML login page |
| Remote EHR | http://localhost:8081/metadata | FHIR CapabilityStatement JSON |

## Step 2 — Seed the remote EHR with test data

The seeder creates 100 synthetic patients, each with encounters, observations, conditions, procedures, allergies, and medication statements.

```bash
cd ehr
uv run python main.py
```

Verify data was created:

```bash
curl -s http://localhost:8081/Patient?_count=1 | jq '.total'
# Expected: 100
```

## Step 3 — Deploy the EHR Importer Bot to Medplum

From the repo root:

```bash
# Deploy only
./ehr/deploy-bot.sh

# Deploy and immediately run the import
./ehr/deploy-bot.sh --run
```

The script will:
1. Authenticate to Medplum as `admin@example.com` / `medplum_admin`
2. Enable the bots feature on the project
3. Create (or find) a Bot named **"EHR Importer"**
4. Compile [ehr/ehr-importer.bot.ts](ehr/ehr-importer.bot.ts) and deploy it
5. (with `--run`) Execute the bot, which pulls all patients and clinical data from the remote EHR into Medplum

On success you'll see:

```
Bot deployed successfully!
  ID:  <bot-id>
  URL: http://localhost:3000/Bot/<bot-id>/editor
```

## Step 4 — Run the import manually (optional)

If you deployed without `--run`, trigger the import from the Medplum app:

1. Open http://localhost:3000 and log in (`admin@example.com` / `medplum_admin`)
2. Navigate to the Bot URL printed by the deploy script
3. Click **Execute**

Or via curl (replace `<token>` and `<bot-id>`):

```bash
curl -X POST http://localhost:8103/fhir/R4/Bot/<bot-id>/\$execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Parameters"}'
```

## Credentials

| Service | Username | Password |
|---|---|---|
| Medplum admin | `admin@example.com` | `medplum_admin` |
| Postgres | `medplum` | `medplum` |
| Redis | — | `medplum` |
| EHR SQL (`sa`) | `sa` | `l0k@fh1rs3rv3r` |

## Stopping the stack

```bash
docker compose -f docker-compose.ehr-stack.yml down
```

To also remove persisted data (Postgres and SQL volumes):

```bash
docker compose -f docker-compose.ehr-stack.yml down -v
```

## Troubleshooting

**`ehr` service keeps restarting**
The FHIR server waits for SQL to finish initializing its schema. This can take 60–90 seconds on first boot. The `restart: on-failure` policy retries automatically — give it a few minutes.

**Bot deploy fails with auth error**
Medplum's default super-admin is created on first startup. If you see a 401, wait for `medplum-server` to be fully healthy and retry.

**`uv` not found**
Install it with `curl -LsSf https://astral.sh/uv/install.sh | sh` or `pip install uv`.

**Port conflicts**
If 3000, 8103, or 8081 are in use locally, stop the conflicting process or edit the port mappings in `docker-compose.ehr-stack.yml`.
