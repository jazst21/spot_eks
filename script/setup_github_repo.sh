#!/usr/bin/env bash
# Configure GitHub repo security settings after creation.
# Requires: gh CLI authenticated (gh auth login)
# Usage: ./setup_github_repo.sh owner/repo
set -euo pipefail

REPO="${1:?Usage: $0 owner/repo}"

echo "==> Enabling secret scanning + push protection"
gh api -X PUT "repos/${REPO}/properties/values" 2>/dev/null || true
gh api -X PATCH "repos/${REPO}" \
  -f security_and_analysis[secret_scanning][status]=enabled \
  -f security_and_analysis[secret_scanning_push_protection][status]=enabled

echo "==> Setting branch protection on main"
gh api -X PUT "repos/${REPO}/branches/main/protection" \
  --input - <<'EOF'
{
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true
  },
  "enforce_admins": true,
  "required_status_checks": {
    "strict": true,
    "contexts": ["gitleaks"]
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false
}
EOF

echo "==> Disabling wiki and projects (not needed)"
gh api -X PATCH "repos/${REPO}" \
  -F has_wiki=false \
  -F has_projects=false \
  -F allow_auto_merge=false

echo ""
echo "Done. Verify at: https://github.com/${REPO}/settings"
echo ""
echo "Manual steps remaining:"
echo "  1. Settings → Branches → main → Restrict pushes → add yourself"
echo "  2. Settings → Collaborators → verify no collaborators"
