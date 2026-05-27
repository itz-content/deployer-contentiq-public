# Playbook helper scripts

These scripts support **IBM Secrets Manager** workflows. They are not used on the default local-secrets install path (`deploy-local.sh` / `-e contentiq_use_local_secrets=true`).

| Script | When to use |
|--------|-------------|
| `check-ibm-sm-apikey-access.sh` | Preflight: IAM token + SM GET before first SM-backed deploy |
| `sync-ibm-sm-secrets-to-cluster.sh` | Manual SM → cluster sync (playbook default uses Ansible tasks in `tasks/fetch-and-apply-ibm-sm-secrets.yml`) |
| `list-ibm-sm-secret-versions.sh` | Audit recent SM versions |
| `push-contentiq-secrets-from-repo-defaults.sh` | Push `ansible/secrets/*.yaml` into SM (requires Writer API key) |

**Default install:** `ansible-playbook … playbooks/deploy.yml` with `contentiq_fetch_secrets_from_ibm_sm: true` (see `ibm-sm-deploy.vars.example.yml` or `tekton/.env.sm`).

**This-run local install:** `../../deploy-local.sh` from the repo root.
