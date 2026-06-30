# workflow-registry

[![Validate Registry](https://github.com/GoCodeAlone/workflow-registry/actions/workflows/validate.yml/badge.svg)](https://github.com/GoCodeAlone/workflow-registry/actions/workflows/validate.yml)
[![Build & Deploy](https://github.com/GoCodeAlone/workflow-registry/actions/workflows/build-pages.yml/badge.svg)](https://github.com/GoCodeAlone/workflow-registry/actions/workflows/build-pages.yml)

The official plugin and template registry for the [GoCodeAlone/workflow](https://github.com/GoCodeAlone/workflow) engine.

**Registry API**: `https://gocodealone.github.io/workflow-registry/v1/`

This registry catalogs built-in plugins, first-party external plugins, community extensions, and reusable templates that can be used with the workflow engine. It serves as the source of truth for the `wfctl` CLI's marketplace and `wfctl publish` command.

## Table of Contents

- [What is this?](#what-is-this)
- [Usage via wfctl](#usage-via-wfctl)
- [Plugin Tiers](#plugin-tiers)
- [Built-in Plugins](#built-in-plugins)
- [First-party External Plugins](#first-party-external-plugins)
- [Community and Premium External Plugins](#community-and-premium-external-plugins)
- [Templates](#templates)
- [Schema](#schema)
- [Submitting a Plugin](#submitting-a-plugin)
- [Automatic Version Tracking](#automatic-version-tracking)
- [Registry Structure](#registry-structure)

---

## What is this?

The workflow engine is built around a plugin system. Every capability — HTTP servers, messaging brokers, state machines, AI steps, CI/CD pipelines — is provided by a plugin. This registry tracks:

- **Plugins**: Packages that extend the engine with new module types, pipeline steps, triggers, and workflow handlers
- **Templates**: Starter configurations for common workflow patterns

The registry is consumed by:
- `wfctl marketplace` — browse and search available plugins
- `wfctl publish` — submit your plugin to the registry
- The workflow UI Marketplace page
- The static JSON API at `https://gocodealone.github.io/workflow-registry/v1/`

---

## Usage via wfctl

```bash
# Search for plugins by keyword
wfctl marketplace search http

# Get details for a specific plugin
wfctl marketplace info payments

# Install a plugin into your project
wfctl install payments

# List all installed plugins
wfctl plugin list

# Update all plugins to latest versions
wfctl plugin update
```

---

## Plugin Tiers

| Tier | Description |
|------|-------------|
| **core** | Maintained by GoCodeAlone as a first-party capability with guaranteed compatibility |
| **community** | Third-party plugins submitted via PR, reviewed by maintainers |
| **premium** | Commercial plugins with additional licensing requirements |

Manifest `type` describes distribution (`builtin`, `external`, or `ui`); `tier` describes ownership and support level.

All plugins in this registry must pass manifest schema validation before merging.

---

## Built-in Plugins

These plugins ship in the `GoCodeAlone/workflow` engine and are available without installing a separate plugin repository.

| Plugin | Description |
|--------|-------------|
| [actors](./plugins/actors/manifest.json) | Actor model support with goakt v4 |
| [admincore](./plugins/admincore/manifest.json) | Core admin-console UI navigation pages, provided as a built-in native plugin |
| [ai](./plugins/ai/manifest.json) | AI pipeline steps (complete, classify, extract), dynamic components, and sub-workflow orchestration |
| [api](./plugins/api/manifest.json) | REST API handlers, CQRS query/command, API gateway, and data transformation |
| [auth](./plugins/auth/manifest.json) | JWT authentication, OAuth2, user store, and auth middleware wiring |
| [cicd](./plugins/cicd/manifest.json) | CI/CD pipeline step types (shell exec, Docker, artifact management, security scanning, deploy, gate, build from config, git operations, AWS CodeBuild) |
| [cloud](./plugins/cloud/manifest.json) | Cloud provider credentials and validation. Foundation for IaC modules. |
| [configprovider](./plugins/configprovider/manifest.json) | Application configuration registry with schema validation, defaults, and source layering |
| [datastores](./plugins/datastores/manifest.json) | NoSQL data store modules and pipeline steps |
| [dlq](./plugins/dlq/manifest.json) | Dead letter queue service module for failed message management |
| [docmanager](./plugins/docmanager/manifest.json) | Markdown documentation management HTTP API (documents and categories), provided as a built-in native plugin |
| [eventstore](./plugins/eventstore/manifest.json) | Event store service module for execution event persistence |
| [featureflags](./plugins/featureflags/manifest.json) | Feature flag service module and pipeline steps (feature_flag, ff_gate) |
| [http](./plugins/http/manifest.json) | HTTP server, router, handlers, middleware, proxy, and static file serving |
| [infra](./plugins/infra/manifest.json) | Abstract infra.* module types with IaCProvider delegation |
| [integration](./plugins/integration/manifest.json) | Integration workflow handler for connector-based multi-system workflows |
| [k8s](./plugins/k8s/manifest.json) | Native Kubernetes deployment support using client-go. Provides generate, apply, destroy, status, diff, and logs operations without requiring kubectl or Helm. |
| [license](./plugins/license/manifest.json) | License validation with remote server, local cache, and grace period |
| [marketplace](./plugins/marketplace/manifest.json) | Plugin marketplace steps for searching, installing, and managing workflow plugins |
| [mcp](./plugins/mcp/manifest.json) | MCP tool triggers, workflow handlers, and server registry |
| [messaging](./plugins/messaging/manifest.json) | Messaging subsystem: brokers, handlers, triggers, and workflows |
| [modularcompat](./plugins/modularcompat/manifest.json) | GoCodeAlone/modular framework compatibility modules (scheduler, cache, jsonschema) |
| [observability](./plugins/observability/manifest.json) | Metrics, health checks, log collection, OpenTelemetry tracing, and OpenAPI spec generation/consumption |
| [openapi](./plugins/openapi/manifest.json) | OpenAPI v3 spec-driven HTTP route generation with request validation and Swagger UI |
| [pipelinesteps](./plugins/pipelinesteps/manifest.json) | Generic pipeline step types, pre-processing validators, and pipeline workflow handler (including base64_decode) |
| [platform](./plugins/platform/manifest.json) | Platform infrastructure modules, workflow handler, reconciliation trigger, and template step |
| [policy](./plugins/policy/manifest.json) | Policy engine plugin with mock backend for testing and development |
| [scheduler](./plugins/scheduler/manifest.json) | Scheduler workflow handler and schedule trigger for cron-based job execution |
| [secrets](./plugins/secrets/manifest.json) | Secrets management modules (Vault, AWS Secrets Manager, OS Keychain) |
| [statemachine](./plugins/statemachine/manifest.json) | State machine engine, tracker, connector modules and workflow handler |
| [storage](./plugins/storage/manifest.json) | Storage, database, persistence, and cache modules with DB pipeline steps |
| [storebrowser](./plugins/storebrowser/manifest.json) | Read-only browser for engine stores (tables, events, dead-letter queue) with a parameterized SQL query endpoint, provided as a built-in native plugin |
| [timeline](./plugins/timeline/manifest.json) | Timeline and replay service module for execution visualization |

## First-party External Plugins

These plugins are maintained by GoCodeAlone as core platform capabilities, but are distributed outside the engine repository.

| Plugin | Description |
|--------|-------------|
| [admin](./plugins/admin/manifest.json) | Admin dashboard UI and config-driven admin routes with embedded React UI. Provides user management, workflow management, settings, and real-time monitoring. |
| [authz](./plugins/authz/manifest.json) | RBAC authorization plugin using Casbin |
| [bento](./plugins/bento/manifest.json) | Stream processing via Bento — 100+ connectors, Bloblang transforms, at-least-once delivery |
| [data-engineering](./plugins/data-engineering/manifest.json) | Data engineering: CDC, lakehouse (Iceberg), time-series (InfluxDB/TimescaleDB/ClickHouse/QuestDB/Druid), graph (Neo4j), data quality, migrations, catalog (DataHub/OpenMetadata) |
| [github](./plugins/github/manifest.json) | GitHub integration plugin: webhook handling, GitHub Actions, PRs, issues, releases, and deployments |
| [portfolio](./plugins/portfolio/manifest.json) | Cross-repo portfolio catalog generator — wfctl portfolio scan\|status for the GoCodeAlone org. Scans repos (git + gh + capability/inventory) into a living catalog (docs/PORTFOLIO.md) + follow-up queue + tooling inventory. CLI-only plugin (no host/gRPC protocol). |
| [workflow-plugin-agent](./plugins/workflow-plugin-agent/manifest.json) | AI agent primitives for workflow apps — provider abstraction (multi-model), execution loop, tool registry, model pull/test |
| [workflow-plugin-approval](./plugins/workflow-plugin-approval/manifest.json) | Human-in-the-loop approval workflows with state machine |
| [workflow-plugin-audit](./plugins/workflow-plugin-audit/manifest.json) | Compliance audit logging with EventBus collection and S3/database sinks |
| [workflow-plugin-auth](./plugins/workflow-plugin-auth/manifest.json) | Passwordless authentication plugin: WebAuthn/passkeys, TOTP, email magic links |
| [workflow-plugin-ci-generator](./plugins/workflow-plugin-ci-generator/manifest.json) | CI/CD config generator for GitHub Actions, GitLab CI, Jenkins, and CircleCI |
| [workflow-plugin-crm](./plugins/workflow-plugin-crm/manifest.json) | Vendor-neutral CRM integration with Salesforce adapter |
| [workflow-plugin-erp](./plugins/workflow-plugin-erp/manifest.json) | Enterprise ERP integration via OData v4 with SAP adapter |
| [workflow-plugin-payments](./plugins/workflow-plugin-payments/manifest.json) | Multi-provider payment processing plugin (Stripe, PayPal) |
| [workflow-plugin-sso](./plugins/workflow-plugin-sso/manifest.json) | Enterprise SSO via OpenID Connect with multi-provider support |
| [workflow-plugin-supply-chain](./plugins/workflow-plugin-supply-chain/manifest.json) | Supply chain security: SBOM generation, keyless signing, SLSA provenance, vulnerability scanning, and wfctl CLI extensions |
| [workflow-plugin-tofu](./plugins/workflow-plugin-tofu/manifest.json) | OpenTofu/Terraform adapter: HCL generation from abstract infra specs, plan/apply execution, and state import/export |
| [workflow-plugin-vectorstore](./plugins/workflow-plugin-vectorstore/manifest.json) | Vector database integration for RAG pipelines with Pinecone support |
| [workflow-plugin-websocket](./plugins/workflow-plugin-websocket/manifest.json) | General-purpose WebSocket support — rooms, broadcast, send, close |

## Community and Premium External Plugins

These plugins are distributed outside the engine repository and are maintained as community or commercial extensions.

| Plugin | Description | Tier |
|--------|-------------|------|
| [authz-ui](./plugins/authz-ui/manifest.json) | Casbin authorization policy management UI (React SPA) | premium |
| [cloud-ui](./plugins/cloud-ui/manifest.json) | Cloud management UI plugin (React SPA) | premium |
| [discord](./plugins/discord/manifest.json) | Discord messaging, bot automation, and voice channel support. Provides a provider module, pipeline steps for sending/editing/deleting messages and managing voice, and a WebSocket Gateway event trigger. | community |
| [scaffold-workflow-plugin](./plugins/scaffold-workflow-plugin/manifest.json) | Template repository for creating workflow engine external plugins | community |
| [security](./plugins/security/manifest.json) | Unified security plugin: WAF (Coraza/AWS/GCloud/Cloudflare), MFA/encryption (TOTP, AES-256-GCM, AWS KMS, GCP KMS, Vault Transit), authorization (Casbin RBAC, Permit.io), data protection (PII detection/masking), sandbox (WASM/wazero, Docker), and supply-chain security (signatures, vuln scanning, SBOM) | premium |
| [slack](./plugins/slack/manifest.json) | Slack messaging and workspace automation. Provides a provider module backed by the Slack Web API and Socket Mode, pipeline steps for messages/blocks/reactions/files, and a Socket Mode event trigger. | community |
| [teams](./plugins/teams/manifest.json) | Microsoft Teams messaging and channel management via the Microsoft Graph API. Provides a provider module with Azure AD client credentials auth, pipeline steps for messages/cards/channels/members, and an HTTP webhook trigger for Graph change notifications. | community |
| [workflow-plugin-analytics](./plugins/workflow-plugin-analytics/manifest.json) | Analytics and tag-manager injection for rendered HTML assets | community |
| [workflow-plugin-atlas-migrate](./plugins/workflow-plugin-atlas-migrate/manifest.json) | Atlas migration driver plugin for the workflow engine | community |
| [workflow-plugin-audit-chain](./plugins/workflow-plugin-audit-chain/manifest.json) | Tamper-evident hash-chained audit logging with periodic Merkle root anchoring (OpenTimestamps/Bitcoin, git, Sigstore) | community |
| [workflow-plugin-auth0](./plugins/workflow-plugin-auth0/manifest.json) | Auth0 identity and access management provider plugin | community |
| [workflow-plugin-aws](./plugins/workflow-plugin-aws/manifest.json) | AWS provider plugin for workflow IaC — manages ECS, EKS, RDS, ElastiCache, VPC, ALB, Route53, ECR, API Gateway, Security Groups, IAM, S3, and ACM resources | community |
| [workflow-plugin-azure](./plugins/workflow-plugin-azure/manifest.json) | Microsoft Azure infrastructure provider: ACI, AKS, SQL, Redis, VNet, LB, DNS, ACR, APIM, NSG, MSI, Blob Storage, App Service Certificates | community |
| [workflow-plugin-botdetect](./plugins/workflow-plugin-botdetect/manifest.json) | Behavioral analysis for bot detection: timing, entropy, session patterns, replay scanning | community |
| [workflow-plugin-broker](./plugins/workflow-plugin-broker/manifest.json) | External plugin for the workflow engine. | community |
| [workflow-plugin-cloudflare](./plugins/workflow-plugin-cloudflare/manifest.json) | Cloudflare DNS provider for workflow IaC (infra.dns) | community |
| [workflow-plugin-cms](./plugins/workflow-plugin-cms/manifest.json) | Multi-tenant CMS engine — TenantResolver + static-wins routing + WYSIWYG page authoring (TipTap default). Foundation of gocodealone-multisite. | community |
| [workflow-plugin-compute-core](./plugins/workflow-plugin-compute-core/manifest.json) | Public compute protocol and provider catalog core for Workflow. | community |
| [workflow-plugin-compute](./plugins/workflow-plugin-compute/manifest.json) | Workflow adapter for workflow-compute dispatch, wait, map, provider, pool, catalog, and product-capture workloads | community |
| [workflow-plugin-datadog](./plugins/workflow-plugin-datadog/manifest.json) | Datadog monitoring and observability — metrics, events, monitors, dashboards, logs, synthetics, SLOs, incidents, and more | community |
| [workflow-plugin-digitalocean](./plugins/workflow-plugin-digitalocean/manifest.json) | DigitalOcean IaC provider: App Platform, DOKS, databases, Redis cache, load balancers, VPC, firewall, DNS, Spaces, DOCR, certificates, Droplets, Block Storage Volumes, IAM, and API gateway | community |
| [workflow-plugin-edge-compute](./plugins/workflow-plugin-edge-compute/manifest.json) | Reusable Edge WASM provider contracts for workflow-compute and compatible edge runtimes | community |
| [workflow-plugin-entra](./plugins/workflow-plugin-entra/manifest.json) | Microsoft Entra ID management provider plugin | community |
| [workflow-plugin-eventbus](./plugins/workflow-plugin-eventbus/manifest.json) | Provisions durable event-bus clusters (NATS / Kafka / Kinesis) as IaC and exposes typed pipeline steps for publish / consume operations. | community |
| [workflow-plugin-gcp](./plugins/workflow-plugin-gcp/manifest.json) | GCP infrastructure provider plugin for workflow — manages Cloud Run, GKE, Cloud SQL, Memorystore, VPC, Load Balancer, Cloud DNS, Artifact Registry, API Gateway, Firewall, IAM, GCS, and Certificate Manager | community |
| [workflow-plugin-gitlab](./plugins/workflow-plugin-gitlab/manifest.json) | GitLab integration plugin: webhook handling and GitLab CI pipeline management | community |
| [workflow-plugin-hover](./plugins/workflow-plugin-hover/manifest.json) | Hover DNS provider for workflow IaC (infra.dns). No official API; mimics the browser-side username+password+TOTP login flow used by pjslauta/hover-dyn-dns. | community |
| [workflow-plugin-infra](./plugins/workflow-plugin-infra/manifest.json) | Plugin-owned infra.* module types (infra.admin, infra.http_redirect); generic infra.* resource types owned by the workflow engine (>= v0.80.17). In-process-only secret-admin steps (ADR 0056 dual-shape, served by NewInfraEnginePlugin not the gRPC binary): step.secret_list, step.secret_delete, step.secret_vault_status, step.secret_vault_test | community |
| [workflow-plugin-launchdarkly](./plugins/workflow-plugin-launchdarkly/manifest.json) | LaunchDarkly feature management — flags, segments, environments, projects, metrics, experiments, approvals, audit log, and more | community |
| [workflow-plugin-media](./plugins/workflow-plugin-media/manifest.json) | Reusable media transforms (ffmpeg) | community |
| [workflow-plugin-messaging-core](./plugins/workflow-plugin-messaging-core/manifest.json) | Shared messaging interfaces for workflow platform plugins | community |
| [workflow-plugin-migrations](./plugins/workflow-plugin-migrations/manifest.json) | Database migration plugin for the workflow engine: golang-migrate + goose + atlas drivers, pre-deploy runner, wfctl db-migrate CLI, static lint tool | community |
| [workflow-plugin-moderation](./plugins/workflow-plugin-moderation/manifest.json) | Trust and safety for game platforms: reputation, bans, text and voice moderation, and admin workflows | community |
| [workflow-plugin-monday](./plugins/workflow-plugin-monday/manifest.json) | Comprehensive monday.com integration — boards, items, columns, groups, workspaces, and all resources via GraphQL | community |
| [workflow-plugin-namecheap](./plugins/workflow-plugin-namecheap/manifest.json) | Namecheap DNS provider for workflow IaC (infra.dns) backed by the official go-namecheap-sdk. | community |
| [workflow-plugin-okta](./plugins/workflow-plugin-okta/manifest.json) | Okta identity and access management — users, groups, applications, authorization servers, MFA, policies, and more | community |
| [workflow-plugin-openlms](./plugins/workflow-plugin-openlms/manifest.json) | OpenLMS learning management — courses, enrollments, grades, assignments, quizzes, users, competencies, calendars, forums, and more | community |
| [workflow-plugin-product-capture](./plugins/workflow-plugin-product-capture/manifest.json) | Product URL capture provider for workflow-compute | community |
| [workflow-plugin-rooms](./plugins/workflow-plugin-rooms/manifest.json) | Room management plugin for workflow engine — join, leave, broadcast, members | community |
| [workflow-plugin-salesforce](./plugins/workflow-plugin-salesforce/manifest.json) | Salesforce CRM — records, SOQL queries, bulk operations, approvals, flows, reports, dashboards, metadata, and more | community |
| [workflow-plugin-scalekit](./plugins/workflow-plugin-scalekit/manifest.json) | Scalekit enterprise SSO and Directory Sync provider plugin | community |
| [workflow-plugin-security-scanner](./plugins/workflow-plugin-security-scanner/manifest.json) | Security scanner plugin for workflow engine — vulnerability scanning, secret detection, and compliance checks | community |
| [workflow-plugin-signal](./plugins/workflow-plugin-signal/manifest.json) | Signal protocol primitives for Workflow | community |
| [workflow-plugin-site-onboarding](./plugins/workflow-plugin-site-onboarding/manifest.json) | Dry-run multisite site/domain onboarding planner for Workflow. | community |
| [workflow-plugin-steam](./plugins/workflow-plugin-steam/manifest.json) | External plugin for the workflow engine. | community |
| [workflow-plugin-stream](./plugins/workflow-plugin-stream/manifest.json) | Live video ingest, multiplex, and restream via MediaMTX | community |
| [workflow-plugin-tournament](./plugins/workflow-plugin-tournament/manifest.json) | Tournament management plugin with bracket engines, scheduling, and prize distribution | community |
| [workflow-plugin-turnio](./plugins/workflow-plugin-turnio/manifest.json) | turn.io WhatsApp API integration — messaging, contacts, templates, flows, and journeys | community |
| [workflow-plugin-twilio](./plugins/workflow-plugin-twilio/manifest.json) | Comprehensive Twilio integration — SMS, Voice, Verify, Video, Conversations, TaskRouter, and 40+ products | community |
| [workflow-plugin-ws-auth](./plugins/workflow-plugin-ws-auth/manifest.json) | WebSocket HMAC authentication plugin for workflow engine | community |

## Templates

Starter configurations for common workflow patterns:

| Template | Description |
|----------|-------------|
| [api-service](./templates/api-service.yaml) | HTTP API with JWT auth, SQLite storage, and composable pipelines |
| [event-processor](./templates/event-processor.yaml) | Event-driven processor using EventBus, pipelines, and optional Kafka/NATS integration |
| [full-stack](./templates/full-stack.yaml) | Full-stack application with HTTP server, auth, state machine, storage, messaging, scheduling, and observability |
| [plugin](./templates/plugin.yaml) | Scaffold for a new external workflow engine plugin with module factory, step factory, and wiring hooks |
| [stream-processor](./templates/stream-processor.yaml) | Stream processing pipeline using the Bento plugin with input ingestion, Bloblang transformation, and output archival |
| [ui-plugin](./templates/ui-plugin.yaml) | Scaffold for a React-based UI plugin that extends the workflow builder with custom node types or pages |

Initialize a project from a template:

```bash
wfctl init my-project --template api-service
```

---

## Schema

All plugin manifests must conform to the [registry schema](./schema/registry-schema.json). The schema is a JSON Schema (draft 2020-12) defining required fields, enums for `type`, `tier`, and `status`, and the structure of `capabilities`.

The optional `status` field tracks active-usage verification: `"verified"` means the plugin is pinned in a merged main-branch `wfctl.yaml` of an active GoCodeAlone project (production miles); `"experimental"` means it compiles and unit-tests pass but has no validated production deployment; `"deprecated"` means it is scheduled for removal. Manifests without `status` continue to validate — the field is optional and additive.

Validate a manifest locally:

```bash
# Validate a single manifest
npx ajv-cli validate --spec=draft2020 -s schema/registry-schema.json -d plugins/my-plugin/manifest.json

# Validate all manifests at once
bash scripts/validate-manifests.sh

# Validate built-in core manifests against workflow plugin declarations
wfctl plugin registry-sync core --workflow-repo /path/to/workflow --registry-dir .

# Validate template plugin references
bash scripts/validate-templates.sh

# Validate the README plugin/template index is current
wfctl plugin registry-sync readme --check --registry-dir .
```

---

## Local Pre-commit Hook

Install the provided pre-commit hook to catch validation errors before they reach CI:

```bash
cp scripts/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

The hook runs `scripts/validate-manifests.sh` when `plugins/*/manifest.json` or `schema/registry-schema.json` are staged, and `scripts/validate-templates.sh` when `templates/*.yaml` files are staged.

---

## CI/CD

Every pull request and push to `main` triggers the [Validate Registry](.github/workflows/validate.yml) workflow, which:

1. Validates all `plugins/*/manifest.json` files against `schema/registry-schema.json` (JSON Schema draft 2020-12 via `ajv-cli`)
2. Checks built-in core plugin manifests against the current `GoCodeAlone/workflow` plugin declarations
3. Checks that `README.md` matches the generated registry index
4. Checks that every plugin referenced in `templates/*.yaml` has a corresponding manifest

The [Sync Registry Manifests](.github/workflows/sync-registry-manifests.yml) workflow runs daily, manually, and on `plugin-release` or `workflow-release` dispatch events. It uses `wfctl plugin registry-sync` to update release metadata, sync built-in core manifests from `GoCodeAlone/workflow`, regenerate this README, and open a PR when tracked registry files change. The old `scripts/sync-versions.sh`, `scripts/sync-core-manifests.sh`, and `scripts/generate-readme.sh` entrypoints are compatibility wrappers around the same `wfctl` commands.

The [Build & Deploy](.github/workflows/build-pages.yml) workflow runs on every push to `main`, on a daily schedule, and whenever a plugin sends a `plugin-release` dispatch event. It:

1. Generates `v1/index.json` from all manifests
2. Queries GitHub Releases for each plugin to build `v1/plugins/<name>/versions.json`
3. Deploys the `v1/` directory to GitHub Pages

PRs that fail validation cannot be merged.

---

## Submitting a Plugin

### Step-by-step PR Process

1. **Fork** this repository
2. **Create** a directory under `plugins/<your-plugin-name>/`
3. **Add** a `manifest.json` that conforms to the [registry schema](./schema/registry-schema.json)
4. **Validate** your manifest locally:
   ```bash
   bash scripts/validate-manifests.sh
   ```
5. **Open a PR** with a description of your plugin, what it provides, and a link to the source repository

### Manifest Requirements

- `name`, `version`, `author`, `description`, `type`, `tier`, `license` are required
- `type` must be `"external"` for community plugins (only GoCodeAlone sets `"builtin"`)
- `tier` must be `"community"` for third-party submissions
- `repository` should point to the public GitHub repository where the plugin lives
- `capabilities.moduleTypes`, `stepTypes`, `triggerTypes`, `workflowHandlers` must accurately reflect what the plugin registers
- `private: true` must be set for plugins that are not publicly installable
- `status` is optional; if set, must be one of `"verified"`, `"experimental"`, or `"deprecated"` (see Schema section)

### Review Process

PRs are reviewed by maintainers for:
- Schema validity
- Accurate capability declarations
- Source repo accessibility
- License compatibility

---

## Automatic Version Tracking

When you publish a new release of your plugin, you can automatically trigger a registry rebuild so that `v1/plugins/<name>/versions.json` and `v1/plugins/<name>/latest.json` are updated within minutes.

See [`templates/notify-registry.yml`](./templates/notify-registry.yml) for the reusable workflow snippet to add to your plugin's release workflow.

**Setup**:
1. Create a GitHub PAT with `repo` scope for `GoCodeAlone/workflow-registry`
2. Add it as a secret named `REGISTRY_PAT` in your plugin repo
3. Copy the `notify-registry` job from the template into your `.github/workflows/release.yml`

The registry rebuilds daily at 06:00 UTC as a fallback even without dispatch events.

---

## Registry Structure

```
workflow-registry/
├── plugins/                    # Source of truth — one directory per plugin
│   └── <name>/
│       └── manifest.json       # Plugin metadata and capabilities
├── templates/                  # Reusable workflow config templates
│   ├── notify-registry.yml     # Action snippet for plugin release notifications
│   └── *.yaml                  # Workflow starter templates
├── schema/
│   └── registry-schema.json    # JSON Schema for manifest validation
├── scripts/
│   ├── build-index.sh          # Generates v1/index.json
│   ├── build-versions.sh       # Queries GitHub Releases → v1/plugins/*/versions.json
│   ├── validate-manifests.sh   # CI manifest validation
│   └── validate-templates.sh   # CI template validation
├── .github/workflows/
│   ├── validate.yml            # PR validation gate
│   └── build-pages.yml         # Build and deploy static registry to GitHub Pages
└── v1/                         # Generated — served via GitHub Pages (not committed)
    ├── index.json              # Array of all plugin summaries, sorted by name
    └── plugins/
        └── <name>/
            ├── manifest.json   # Copy of source manifest
            ├── versions.json   # Release history from GitHub
            └── latest.json     # Latest release entry only
```

### Static API Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /v1/index.json` | All plugin summaries (name, description, version, capabilities, ...) |
| `GET /v1/plugins/<name>/manifest.json` | Full manifest for a specific plugin |
| `GET /v1/plugins/<name>/versions.json` | All release versions with download URLs |
| `GET /v1/plugins/<name>/latest.json` | Latest release version only |

---

## Plugin Authoring Guide

See the [Plugin Manifest Format](#plugin-manifest-format) section below and the [registry schema](./schema/registry-schema.json) for a complete reference on building, testing, and publishing a workflow engine plugin.

---

## Plugin Manifest Format

```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "author": "your-github-username",
  "description": "What this plugin provides",
  "source": "github.com/yourorg/my-plugin",
  "path": ".",
  "type": "external",
  "tier": "community",
  "license": "MIT",
  "minEngineVersion": "0.1.0",
  "repository": "https://github.com/yourorg/my-plugin",
  "keywords": ["tag1", "tag2"],
  "capabilities": {
    "moduleTypes": ["mymodule.type"],
    "stepTypes": ["step.my_step"],
    "triggerTypes": [],
    "workflowHandlers": []
  }
}
```

Full schema documentation: [`schema/registry-schema.json`](./schema/registry-schema.json)

---

## License

MIT — see [LICENSE](./LICENSE)
