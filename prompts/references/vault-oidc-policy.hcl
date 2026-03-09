# Vault: JWT auth role for GitHub Actions OIDC.
# Scope is locked to the exact repo and the "staging" environment.
# Production gets a separate role with a separate policy.

resource "vault_jwt_auth_backend_role" "ansible_deploy_staging" {
  backend        = vault_jwt_auth_backend.github.path
  role_name      = "ansible-deploy-staging"
  token_policies = ["ansible-staging-policy"]

  bound_claims = {
    repository = "droxey/clincher"
    environment = "staging"
    ref_type    = "tag"
  }

  user_claim = "actor"
  role_type  = "jwt"
  ttl        = "900"
}
