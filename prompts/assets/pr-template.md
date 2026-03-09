## Summary

<!-- What does this PR change? Which roles/tasks? -->

## Test Plan

- [ ] `ansible-lint --profile production` passes locally
- [ ] `molecule test` passes for affected roles
- [ ] `ansible-playbook --syntax-check` passes
- [ ] Tested against staging with `--check --diff` before merging

## Security Checklist

- [ ] No secrets in plaintext — vault-encrypted or omitted
- [ ] `no_log: true` on all tasks handling sensitive data
- [ ] `become: true` scoped to task level only
- [ ] New Galaxy dependencies reviewed for known CVEs
