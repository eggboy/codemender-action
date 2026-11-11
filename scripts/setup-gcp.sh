#!/usr/bin/env bash
# One-time Google Cloud setup for the CodeMender GitHub Action.
#
# Run once per Google Cloud project and GitHub owner. Creates:
#   - a service account with roles/aiplatform.user (the only role CodeMender needs)
#   - a Workload Identity pool and a GitHub OIDC provider limited to GITHUB_OWNER
#   - a workloadIdentityUser binding for each repository in REPOS
#
# No service account keys are created. GitHub Actions authenticates with short-lived
# OIDC tokens through google-github-actions/auth.
#
# Usage:
#   PROJECT_ID=my-project GITHUB_OWNER=my-org REPOS="my-org/app my-org/api" ./scripts/setup-gcp.sh
#
# Optional: POOL_ID (default github), PROVIDER_ID (default github-actions), SA_ID (default codemender-ci).
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID to the Google Cloud project with CodeMender access}"
: "${GITHUB_OWNER:?set GITHUB_OWNER to the GitHub organization or user that owns the repositories}"
: "${REPOS:?set REPOS to a space-separated list of owner/repository}"
POOL_ID="${POOL_ID:-github}"
PROVIDER_ID="${PROVIDER_ID:-github-actions}"
SA_ID="${SA_ID:-codemender-ci}"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Enabling APIs"
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com \
  cloudresourcemanager.googleapis.com aiplatform.googleapis.com --project "$PROJECT_ID"

if gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "Service account $SA_EMAIL exists"
else
  echo "Creating service account $SA_EMAIL"
  gcloud iam service-accounts create "$SA_ID" --project "$PROJECT_ID" --display-name "CodeMender CI"
fi

echo "Granting roles/aiplatform.user to $SA_EMAIL"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:${SA_EMAIL}" --role roles/aiplatform.user --condition=None >/dev/null

if gcloud iam workload-identity-pools describe "$POOL_ID" --project "$PROJECT_ID" --location global >/dev/null 2>&1; then
  echo "Workload Identity pool $POOL_ID exists"
else
  echo "Creating Workload Identity pool $POOL_ID"
  gcloud iam workload-identity-pools create "$POOL_ID" --project "$PROJECT_ID" --location global \
    --display-name "GitHub Actions"
fi

if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" --project "$PROJECT_ID" \
  --location global --workload-identity-pool "$POOL_ID" >/dev/null 2>&1; then
  echo "Provider $PROVIDER_ID exists"
else
  echo "Creating OIDC provider $PROVIDER_ID (tokens accepted only from repositories owned by $GITHUB_OWNER)"
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
    --project "$PROJECT_ID" --location global --workload-identity-pool "$POOL_ID" \
    --display-name "GitHub Actions" \
    --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition "assertion.repository_owner == '${GITHUB_OWNER}'" \
    --issuer-uri https://token.actions.githubusercontent.com
fi

POOL_NAME=$(gcloud iam workload-identity-pools describe "$POOL_ID" --project "$PROJECT_ID" \
  --location global --format 'value(name)')
for repo in $REPOS; do
  echo "Allowing workflows in $repo to impersonate $SA_EMAIL"
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" --project "$PROJECT_ID" \
    --role roles/iam.workloadIdentityUser \
    --member "principalSet://iam.googleapis.com/${POOL_NAME}/attribute.repository/${repo}" >/dev/null
done

PROVIDER_NAME=$(gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" --project "$PROJECT_ID" \
  --location global --workload-identity-pool "$POOL_ID" --format 'value(name)')

cat <<EOF

Done. Add these as repository (or organization) Actions secrets:

  GCP_PROJECT_ID=${PROJECT_ID}
  GCP_WIF_PROVIDER=${PROVIDER_NAME}
  GCP_WIF_SERVICE_ACCOUNT=${SA_EMAIL}

IAM changes can take up to five minutes to take effect.
EOF
