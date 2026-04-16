# Deployment configuration (what to edit before install)

Ansible playbooks live under **`ansible/playbooks/`**. They only reference files under **`ansible/`** (manifests, secrets, tasks, roles).

The flow creates the namespace, OLM catalog/subscription, applies your secrets and Custom Resource (CR), then waits for rollouts.

## How to run

From the **`ansible/`** directory (after `oc login` and installing collections from `requirements.yml` if needed):

```bash
ansible-playbook -i inventory.yml playbooks/deploy.yml -e @parameters.yml
```

Teardown (removes the install; read `playbooks/teardown.yml` for flags):

```bash
ansible-playbook -i inventory.yml playbooks/teardown.yml -e @parameters.yml -e contentiq_teardown_confirm=true
```

Or from `contentiq-operator-deployment/`: `./teardown.sh` (adds `contentiq_teardown_confirm=true`).

## Files customers must customize (under `ansible/`)

### 1. `ansible/secrets/backend-secrets-template.yaml`

Kubernetes Secret `contentiq-backend-secrets` in namespace `contentiq`. Replace placeholder values (e.g. `<REPLACE_ME>`) with real credentials.

Typical areas to edit:

- **Cloud / storage**: AWS keys, bucket name/ARN, region; any IBM Cloud or other vendor URLs and tokens you use.
- **AI / search**: API keys (Groq, OpenAI, Zilliz, etc.) your deployment requires.
- **Data stores**: MongoDB URI and database name.
- **OAuth / connectors**: Microsoft, Box, Google redirect URIs and client IDs/secrets — these must match the **public URLs** your users will use (see routes in `ansible/manifests/contentiq-custom-resource.yaml`).
- **Frontend/backend URLs**: `FRONTEND_URL`, `CORS_ALLOWED_ORIGINS`, `SESSION_COOKIE_DOMAIN` — align with the OpenShift routes (or hostnames) you configure in the CR.

Do **not** set `REDIS_URL` here; the operator manages Redis and injects the correct value.

After changes, apply the manifest (the playbook applies it for you on install, or from the bundle root: `oc apply -f ansible/secrets/backend-secrets-template.yaml`). Pods may need `oc rollout restart` to pick up secret changes.

### 2. `ansible/secrets/rag-secrets-template.yaml`

Secret for the personalization RAG workload (`personalization-api-secrets`). Edit placeholders the same way as the backend template.

The main playbook applies this in Step 5b by default (`contentiq_apply_rag_secret: true`). Set `contentiq_apply_rag_secret: false` in `ansible/parameters.yml` only if you are not running the RAG workload or you apply the secret yourself.

### 3. `ansible/manifests/contentiq-custom-resource.yaml`

The `ContentIQ` CR (`contentiq-instance`). This drives images, replicas, routes, resource limits, and Structured Data options.

Customers usually change:

- **`spec.images`**: Frontend, backend, RAG (and optionally Redis) image references — point at your registry/tags (required for air-gap).
- **`spec.routes`**: `hostname` values for frontend and backend routes so URLs match DNS and TLS expectations.
- **`imagePullSecrets`** (optional): If images are in a private registry, reference the pull secret name(s) the operator should use.
- **Replicas and resources**: Tune `backendReplicas`, `frontendReplicas`, `ragReplicas`, and resource blocks for your cluster size.

Keep `metadata.name` / namespace consistent with what the playbooks and docs expect unless you intentionally rename and update every reference.

## Related automation vars

`ansible/parameters.yml` holds registry credentials for the **docker pull secret** the playbooks create (`contentiq_manage_pull_secret`) and optional toggles (e.g. defer phase-2/Step 7 on tiny clusters, RAG secret apply, manifest path overrides). It is separate from the Kubernetes secret files above.
