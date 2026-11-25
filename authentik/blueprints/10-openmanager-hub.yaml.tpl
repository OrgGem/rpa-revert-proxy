# ==============================================================================
# Authentik Blueprint v1 — Central HAProxy OpenManager SSO Protection
# Rendered by: python3 scripts/render_configs.py -> authentik/blueprints/10-openmanager-hub.yaml
# ==============================================================================
version: 1
metadata:
  name: "RPA Central HAProxy OpenManager Protection"
  labels:
    blueprints.goauthentik.io/instantiate: "true"

entries:
  # 1. Infra Admins Group (Only members of this group may access OpenManager UI)
  - model: authentik_core.group
    id: group_infra_admins
    state: present
    identifiers:
      name: "${AUTHENTIK_ALLOWED_GROUP}"
    attrs:
      name: "${AUTHENTIK_ALLOWED_GROUP}"
      is_superuser: false

  # 2. Standalone Proxy Provider pointing to internal Zero-Nginx openmanager-router:8080
  - model: authentik_providers_proxy.proxyprovider
    id: provider_openmanager_hub
    state: present
    identifiers:
      name: "openmanager-hub-proxy"
    attrs:
      name: "openmanager-hub-proxy"
      mode: "proxy"
      external_host: "https://${OPENMANAGER_PUBLIC_DOMAIN}"
      internal_host: "${OPENMANAGER_INTERNAL_URL}"
      internal_host_ssl_validation: false
      authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
      invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]

  # 3. Application entry for Central HAProxy OpenManager
  - model: authentik_applications.application
    id: app_openmanager_hub
    state: present
    identifiers:
      slug: "haproxy-openmanager"
    attrs:
      name: "HAProxy OpenManager Central Portal"
      slug: "haproxy-openmanager"
      provider: !KeyOf provider_openmanager_hub
      policy_engine_mode: "all"

  # 4. Strict Group Policy Binding (Non-members receive HTTP 403 at Proxy layer)
  - model: authentik_policies.policybinding
    state: present
    identifiers:
      target: !KeyOf app_openmanager_hub
      group: !KeyOf group_infra_admins
      order: 0
    attrs:
      enabled: true
      negate: false
      timeout: 30

  # 5. Single Hub Proxy Outpost
  - model: authentik_outposts.outpost
    id: outpost_openmanager_hub
    state: present
    identifiers:
      name: "outpost-openmanager-hub"
    attrs:
      name: "outpost-openmanager-hub"
      type: "proxy"
      providers:
        - !KeyOf provider_openmanager_hub
      config:
        authentik_host: "${AUTHENTIK_HOST}"
        authentik_host_insecure: ${AUTHENTIK_INSECURE}
