#!/usr/bin/env bash
#
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Safely applies the Agent Gateway tenant-project Service Extensions SA IAM
# bindings (`module.agent_gateway[0].google_project_iam_member.service_extensions_sa`)
# in Argolis (or any GCP organization enforcing `constraints/iam.allowedPolicyMemberDomains`
# with automated compliance checks).
#
# Background:
#   - Agent Gateway runs its data-plane proxy in a Google-managed tenant project.
#   - Its CONTENT_AUTHZ callout to Model Armor authenticates as
#     `service-<TENANT_PROJECT_NUMBER>@gcp-sa-dep.iam.gserviceaccount.com`, which
#     lives outside your GCP organization.
#   - Domain Restricted Sharing (`iam.allowedPolicyMemberDomains`) blocks adding
#     that external service account to your project's IAM policy, but in Argolis,
#     leaving DRS permanently overridden risks project suspension.
#   - Because DRS only evaluates at `setIamPolicy` write time (and does not
#     revoke existing bindings once reset), the safe Argolis workflow is:
#       1. Temporarily override `iam.allowedPolicyMemberDomains` (`allowAll: true`).
#       2. Apply the IAM role bindings via Terraform.
#       3. Immediately reset `iam.allowedPolicyMemberDomains` to inherit parent
#          rules (enforced via an `EXIT` trap so it always runs).
#
# Usage:
#   ./scripts/apply_argolis_tenant_sa_iam.sh [options]
#
# Options (flag wins over env var; PROJECT_ID auto-detects from terraform/terraform.tfvars):
#   --project <PROJECT_ID>        [env PROJECT_ID]
#                                 Target GCP project ID. If omitted, parsed from
#                                 terraform/terraform.tfvars.
#   --wait-seconds <SECONDS>      [env WAIT_SECONDS, default: 25]
#                                 Seconds to wait after setting the temporary
#                                 Org Policy override before running Terraform.
#   --full-apply                  [env FULL_APPLY]
#                                 Run a full `terraform apply -auto-approve`
#                                 instead of targeting only
#                                 `module.agent_gateway[0].google_project_iam_member.service_extensions_sa`.
#   -h, --help                    Show this help text.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

PROJECT_ID="${PROJECT_ID:-}"
WAIT_SECONDS="${WAIT_SECONDS:-25}"
FULL_APPLY="${FULL_APPLY:-}"

value_for() {
	local flag="$1" candidate="${2:-}"
	if [ -z "${candidate}" ] || [[ ${candidate} == --* ]]; then
		echo "${flag} requires a value" >&2
		exit 1
	fi
	printf '%s' "${candidate}"
}

while [ $# -gt 0 ]; do
	case "$1" in
	--project)
		PROJECT_ID="$(value_for "$1" "${2:-}")"
		shift 2
		;;
	--wait-seconds)
		WAIT_SECONDS="$(value_for "$1" "${2:-}")"
		shift 2
		;;
	--full-apply)
		FULL_APPLY=1
		shift
		;;
	-h | --help)
		sed -n '17,51p' "$0"
		exit 0
		;;
	*)
		echo "Unknown flag: $1 (run with -h for usage)" >&2
		exit 1
		;;
	esac
done

# Auto-detect project_id from terraform/terraform.tfvars if not explicitly provided.
if [ -z "${PROJECT_ID}" ] && [ -f "${TF_DIR}/terraform.tfvars" ]; then
	PROJECT_ID="$(sed -nE 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "${TF_DIR}/terraform.tfvars" | head -n 1)"
fi

: "${PROJECT_ID:?PROJECT_ID is required (pass --project <ID>, set env PROJECT_ID, or set project_id in terraform/terraform.tfvars)}"

for cmd in gcloud terraform; do
	command -v "$cmd" >/dev/null 2>&1 || {
		echo "Missing required command: $cmd" >&2
		exit 1
	}
done

TMP_POLICY="$(mktemp "${TMPDIR:-/tmp}/drs_allow_all.XXXXXX.yaml")"
POLICY_OVERRIDDEN=0

cleanup() {
	local exit_code=$?
	rm -f "${TMP_POLICY}"
	if [ "${POLICY_OVERRIDDEN}" -eq 1 ]; then
		echo
		echo "=== Step 3: Resetting iam.allowedPolicyMemberDomains on ${PROJECT_ID} to inherit parent rules ==="
		if ! gcloud org-policies reset iam.allowedPolicyMemberDomains --project="${PROJECT_ID}"; then
			echo "WARNING: Failed to reset iam.allowedPolicyMemberDomains automatically!" >&2
			echo "Run manually: gcloud org-policies reset iam.allowedPolicyMemberDomains --project=${PROJECT_ID}" >&2
			exit 1
		fi
	fi
	exit "${exit_code}"
}
trap cleanup EXIT INT TERM

echo "Ensuring orgpolicy.googleapis.com is enabled on ${PROJECT_ID}..."
gcloud services enable orgpolicy.googleapis.com --project="${PROJECT_ID}"

cat >"${TMP_POLICY}" <<EOF
name: projects/${PROJECT_ID}/policies/iam.allowedPolicyMemberDomains
spec:
  rules:
  - allowAll: true
EOF

echo
echo "=== Step 1: Temporarily overriding iam.allowedPolicyMemberDomains (allowAll: true) on ${PROJECT_ID} ==="
gcloud org-policies set-policy "${TMP_POLICY}" --project="${PROJECT_ID}"
POLICY_OVERRIDDEN=1

echo "Waiting ${WAIT_SECONDS}s for Org Policy propagation..."
sleep "${WAIT_SECONDS}"

echo
echo "=== Step 2: Applying Terraform IAM bindings for Agent Gateway tenant SA ==="
cd "${TF_DIR}"
if [ -n "${FULL_APPLY}" ]; then
	terraform apply -auto-approve
else
	terraform apply -auto-approve \
		-target='module.agent_gateway[0].google_project_iam_member.service_extensions_sa'
fi
