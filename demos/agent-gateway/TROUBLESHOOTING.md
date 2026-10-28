# Agent Gateway Codelab — Troubleshooting & Fixes Guide

This document summarizes the troubleshooting steps, root causes, and fixes identified while walking through the **Governing agentic workloads with Agent Gateway on Gemini Enterprise Agent Platform** (`cloudnet-agent-gateway`) codelab, categorized chronologically by **Order of Application** and **Importance**.

---

## Quick Reference Matrix

| Order | Phase | Issue | Importance | Status |
| :--- | :--- | :--- | :--- | :--- |
| **1.1** | 1. Terraform Apply | Service Identity & Agent Identity Workload Pool propagation race conditions (`400` errors) | **Critical (Blocker)** | Fixed in repo & applied |
| **1.2** | 1. Terraform Apply | Argolis Domain Restricted Sharing (DRS) blocking Agent Gateway tenant SA (`gcp-sa-dep`) | **Critical (Argolis Blocker)** | Fixed via [`scripts/apply_argolis_tenant_sa_iam.sh`](scripts/apply_argolis_tenant_sa_iam.sh) |
| **1.3** | 1. Terraform Apply | `gcloud beta services mcp` invalid choice in Model Armor floor setting | **Critical (Blocker)** | Fixed in repo & applied |
| **2.1** | 2. Cloud Run (`skaffold`) | MCP containers failing startup (`PermissionError` on `/app/server.py` due to host `umask 027`) | **Critical (Blocker)** | Fixed in Dockerfiles & deployed |
| **3.1** | 3. Agent & IAP Grants | Missing `jq` binary & required environment variables for [`scripts/grant_agent_mcp_egress.sh`](scripts/grant_agent_mcp_egress.sh) | **Medium (Prerequisite)** | Resolved in environment |
| **3.2** | 3. Agent & IAP Grants | `uv sync` / `uv run` on gLinux (Cloudtop) rewriting [`src/mortgage-agent/uv.lock`](src/mortgage-agent/uv.lock) to internal Airlock proxy URLs | **Low (Git / Local Env)** | Revert & use `--frozen` |
| **3.3** | 3. Agent & IAP Grants | Unconditional `roles/iap.egressor` grant overriding `ReadOnlyToolsOnly` CEL condition on `corporate-email` | **High (Functional Bug)** | Fixed via IAP `:setIamPolicy` |
| **4.1** | 4. IAP Enforcement | Unquoted `null` vs `"null"` in `terraform.tfvars` & expired ADC RAPT token | **Medium (Configuration)** | Fixed & applied |
| **4.2** | 4. IAP Enforcement | `google-adk` swallowing HTTP `403` inside `TaskGroup` and bypassing `_handle_tool_error` | **Low (UX Enhancement)** | Documented for reference |

---

## Phase 1: Infrastructure Provisioning (`terraform apply`)

### 1.1. Service Identity & Workload Identity Pool Propagation Race Conditions — **[Critical / Blocker]**

- **Symptom:**
  Initial `terraform apply` failed when binding IAM roles to newly generated Google-managed service agents (`gcp-sa-aiplatform`, `gcp-sa-networkservices`) and the organization-scoped Agent Identity pool (`principalSet://agents.global.org-<ORG_ID>.system.id.goog/attribute.platformContainer/aiplatform/projects/<PROJECT_NUMBER>`).
- **Root Cause:**
  Provisioning the `aiplatform.googleapis.com` service identity asynchronously initializes the org-level workload identity pool (`workpool`). The original 30-second conditional sleep in `foundation` was too short, and `modules/agent-engine` had no propagation delay gating its 11 `agent_identity_*` bindings.
- **Fix Applied:**
  - [`terraform/modules/foundation/main.tf`](terraform/modules/foundation/main.tf): Made `time_sleep.aiplatform_identity_propagation` unconditional, increased `create_duration` from `"30s"` to `"60s"`, and added `google_project_service_identity.network_services` to `depends_on`.
  - [`terraform/modules/agent-engine/main.tf`](terraform/modules/agent-engine/main.tf) & [`terraform/modules/agent-engine/versions.tf`](terraform/modules/agent-engine/versions.tf): Added `time_sleep.agent_identity_pool_propagation` (`create_duration = "60s"`) and added `depends_on` across all 11 `google_project_iam_member.agent_identity_*` resources.

### 1.2. Argolis Domain Restricted Sharing (DRS) Blocking Agent Gateway Tenant SA — **[Critical / Argolis Blocker]**

- **Symptom:**
  `terraform apply` failed on `module.agent_gateway[0].google_project_iam_member.service_extensions_sa` (`roles/modelarmor.calloutUser`, `roles/modelarmor.user`, `roles/serviceusage.serviceUsageConsumer`) due to `constraints/iam.allowedPolicyMemberDomains`.
- **Root Cause:**
  The Agent Gateway's `service_extensions_service_account` (`service-<TENANT_PROJECT_NUMBER>@gcp-sa-dep.iam.gserviceaccount.com`) lives in a Google-managed tenant project outside the Argolis organization, which DRS blocks when adding new IAM bindings.
- **Fix Applied:**
  Created and ran the 3-step helper script [`scripts/apply_argolis_tenant_sa_iam.sh`](scripts/apply_argolis_tenant_sa_iam.sh), which:
  1. Temporarily sets `allowAll: true` on `iam.allowedPolicyMemberDomains` for the project,
  2. Runs `terraform apply -target='module.agent_gateway[0].google_project_iam_member.service_extensions_sa'`, and
  3. Immediately resets the org policy via an `EXIT`/`INT`/`TERM` trap (`gcloud org-policies reset iam.allowedPolicyMemberDomains`) so the Argolis project is never left non-compliant.

### 1.3. Model Armor 1P MCP Floor Setting CLI Failure — **[Critical / Blocker]**

- **Symptom:**
  `module.model_armor[0].null_resource.mcp_content_security[0]` failed with `ERROR: (gcloud.beta.services) Invalid choice: 'mcp'`.
- **Root Cause:**
  `enable_model_armor_mcp_floor_setting` defaulted to `true` and shelled out to `gcloud beta services mcp content-security add`. That command is only used for 1P Google MCP servers (such as BigQuery MCP) and is not available in standard Cloud SDK installs; custom Cloud Run MCP servers are already protected by the Agent Gateway's `CONTENT_AUTHZ` Model Armor policy.
- **Fix Applied:**
  Set `enable_model_armor_mcp_floor_setting = false` in [`terraform/variables.tf`](terraform/variables.tf) and [`terraform/terraform.tfvars`](terraform/terraform.tfvars).

---

## Phase 2: MCP Server Container Build & Deployment (`skaffold run`)

### 2.1. Cloud Run Startup Crash (`PermissionError: [Errno 13] Permission denied: '/app/server.py'`) — **[Critical / Blocker]**

- **Symptom:**
  `skaffold run` built the images in Cloud Build, but Cloud Run revisions failed to become healthy (`failed to start and listen on port 8080`). Revision logs showed `PermissionError: [Errno 13] Permission denied: '/app/server.py'`.
- **Root Cause:**
  On workstations with a restrictive default `umask` (such as `027`), checked-out source files have `0640` (`-rw-r-----`) permissions. Plain `COPY . .` in the Dockerfiles copied them as `root:root` (`0:0`) with `0640` permissions, making `server.py` unreadable by the non-root runtime user (`USER 65532:65532`).
- **Fix Applied:**
  Updated `COPY` to `COPY --chown=65532:65532` in:
  - [`src/legacy-dms/Dockerfile`](src/legacy-dms/Dockerfile)
  - [`src/corporate-email/Dockerfile`](src/corporate-email/Dockerfile)
  - [`src/income-verification-api/Dockerfile`](src/income-verification-api/Dockerfile)

---

## Phase 3: Agent Deployment & Per-MCP IAP Egress Grants

### 3.1. Missing `jq` & Environment Variables for [`scripts/grant_agent_mcp_egress.sh`](scripts/grant_agent_mcp_egress.sh) — **[Medium / Prerequisite]**

- **Symptom:**
  Running `./scripts/grant_agent_mcp_egress.sh --bind-all-agents --endpoints` exited with `Missing required command: jq` and required environment variables not explicitly shown in the codelab snippet.
- **Fix Applied:**
  Installed `jq` (`sudo apt-get install -y jq`) and exported `PROJECT_ID`, `PROJECT_NUMBER`, `ORG_ID`, and `REGION` before invoking the script:
  ```bash
  export PROJECT_ID="<your-project-id>"
  export PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
  export ORG_ID="<your-org-id>"
  export REGION="us-central1"
  ```

### 3.2. `uv sync` / `uv run` Rewriting [`src/mortgage-agent/uv.lock`](src/mortgage-agent/uv.lock) on gLinux / Cloudtop — **[Low / Git Hygiene]**

- **Symptom:**
  Running `git diff` after `uv sync` or `uv run python deploy_agent.py` shows thousands of modified lines in [`src/mortgage-agent/uv.lock`](src/mortgage-agent/uv.lock).
- **Root Cause:**
  On gLinux / Cloudtop, the default Python index routes through Google's internal Airlock PyPI proxy (`http://airlock-proxy.uplink.goog:999/...`). When `uv sync` or `uv run` executes without `--frozen`, `uv` rewrites every package's `source`, `sdist`, and `wheels` URLs in `uv.lock` from `https://pypi.org/simple` to `http://airlock-proxy.uplink.goog:999/...`. Committing those changes breaks external builds and leaks internal proxy URLs.
- **Fix / Workaround:**
  1. Discard the lockfile diff before committing:
     ```bash
     git checkout -- src/mortgage-agent/uv.lock
     ```
  2. Pass `--frozen` when running `uv` on Cloudtop so it uses the existing lockfile without modifying it:
     ```bash
     uv sync --frozen
     uv run --frozen python deploy_agent.py ...
     ```

### 3.3. Duplicate Unconditional `roles/iap.egressor` Binding Overriding CEL Condition on `corporate-email` — **[High / Functional Bug]**

- **Symptom:**
  Even after enabling IAP enforcement (`dryRun: false`), calling `corporate_email_send_email` in Agent Playground succeeded instead of being blocked with `403 Forbidden`.
- **Root Cause:**
  1. Codelab Step #12 (`#12`) includes an unfiltered snippet at the bottom under "Additional Use Cases" (`./scripts/grant_agent_mcp_egress.sh --mcp --agent-id ${AGENT_ID}`), which grants unconditional `roles/iap.egressor` on **all** MCP servers, including `corporate-email`.
  2. `apply_policy` in [`scripts/grant_agent_mcp_egress.sh`](scripts/grant_agent_mcp_egress.sh) merges bindings additively (`OR` semantics) when `.condition` differs, leaving **both** an unconditional binding and the `ReadOnlyToolsOnly` conditional binding on `corporate-email`.
- **Fix Applied:**
  Overwrote the IAP IAM policy on `corporate-email` via `:setIamPolicy` so that only the conditional `ReadOnlyToolsOnly` binding remained:
  ```bash
  TOKEN="$(gcloud auth application-default print-access-token)"
  curl -sS -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "https://iap.googleapis.com/v1/projects/${PROJECT_NUMBER}/locations/${REGION}/iap_web/agentRegistry/mcpServers/${CORP_EMAIL_MCP_ID}:setIamPolicy" \
    -d "{
      \"policy\": {
        \"version\": 3,
        \"bindings\": [
          {
            \"role\": \"roles/iap.egressor\",
            \"members\": [
              \"principal://agents.global.org-${ORG_ID}.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${AGENT_ID}\"
            ],
            \"condition\": {
              \"title\": \"ReadOnlyToolsOnly\",
              \"description\": \"Restrict ${AGENT_ID} to read-only tools on corporate-email\",
              \"expression\": \"api.getAttribute('iap.googleapis.com/mcp.tool.isReadOnly', false) == true || api.getAttribute('iap.googleapis.com/mcp.toolName', '') == ''\"
            }
          }
        ]
      }
    }" | jq .
  ```

---

## Phase 4: Enforcing IAP Authorization & Tool Error Handling

### 4.1. Unquoted `null` in `terraform.tfvars` & ADC Re-authentication — **[Medium / Configuration]**

- **Symptom:**
  Setting `agent_gateway_iap_iam_enforcement_mode = "null"` (quoted string) failed variable validation in [`terraform/variables.tf`](terraform/variables.tf), and Terraform state access initially failed with `invalid_grant (invalid_rapt)`.
- **Fix Applied:**
  Refreshed Application Default Credentials (`gcloud auth application-default login`) and set unquoted `agent_gateway_iap_iam_enforcement_mode = null` in [`terraform/terraform.tfvars`](terraform/terraform.tfvars), updating `google_network_services_authz_extension.iap` (`agent-gateway-iap-authz`) in [`terraform/modules/agent-gateway/main.tf`](terraform/modules/agent-gateway/main.tf) to remove `iamEnforcementMode: "DRY_RUN"`.

### 4.2. ADK `McpTool` Swallowing HTTP `403` Exceptions as `TaskGroup` Connection Errors — **[Low / UX Enhancement (Reference)]**

- **Symptom:**
  When IAP blocks `corporate_email_send_email` with HTTP `403`, the function response returns `"Unexpected error during MCP tool execution: MCP session connection lost: unhandled errors in a TaskGroup (1 sub-exception)"`, causing the agent to tell the user the email server has a connection issue rather than an authorization policy restriction.
- **Root Cause:**
  `ADK_ENABLE_MCP_GRACEFUL_ERROR_HANDLING="true"` in [`src/mortgage-agent/deploy_agent.py`](src/mortgage-agent/deploy_agent.py) causes `McpTool.run_async` in `google-adk==1.34.0` to catch the `ConnectionError` (wrapping AnyIO's `ExceptionGroup` -> `httpx.HTTPStatusError: 403 Forbidden`) and return an `{"error": ...}` dict instead of raising. Because no exception escapes `run_async`, ADK never invokes `on_tool_error_callback` (`_handle_tool_error` in [`src/mortgage-agent/agent/agent.py`](src/mortgage-agent/agent/agent.py)).
- **Reference Solution:**
  Record the HTTP status code in `_ImpersonatedIDTokenAuth.auth_flow` (`response = yield request`) and add an `after_tool_callback` in [`src/mortgage-agent/agent/agent.py`](src/mortgage-agent/agent/agent.py) to rewrite the swallowed `TaskGroup` error dictionary into an explicit authorization policy denial message:
  ```python
  def _handle_after_tool(
      tool: BaseTool,
      args: dict[str, Any],
      tool_context: ToolContext,
      tool_response: dict,
  ) -> dict | None:
      """Rewrite swallowed MCP TaskGroup 403 errors into clear authz denial messages."""
      if not isinstance(tool_response, dict):
          return None
      err_msg = str(tool_response.get("error", ""))
      if "MCP session connection lost" in err_msg and (
          _LAST_MCP_HTTP_STATUS == 403 or "403" in err_msg
      ):
          return {
              "error": (
                  f"The '{tool.name}' tool call was blocked by Agent Gateway / IAP "
                  f"authorization policy (HTTP 403 Forbidden). "
                  f"Do not call '{tool.name}' again in this session — inform the user "
                  f"that this action is restricted by an authorization policy."
              ),
          }
      return None
  ```
