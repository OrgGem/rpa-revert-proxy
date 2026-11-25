#!/usr/bin/env bash
# ==============================================================================
# fetch-outpost-token.sh — Retrieve Hub Outpost Token from Authentik & Update .env
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "[FAIL] Missing ${ENV_FILE}." >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

API_TOKEN="${1:-${LOCAL_IDP_BOOTSTRAP_TOKEN:-}}"
if [[ -z "${API_TOKEN}" || "${API_TOKEN}" == CHANGE_ME_* ]]; then
    echo "[FAIL] Pass an Authentik Admin API Token as arg 1 (or set LOCAL_IDP_BOOTSTRAP_TOKEN in .env)." >&2
    exit 1
fi

OUTPOST_NAME="outpost-openmanager-hub"
CURL_INSECURE_FLAG=()
if [[ "${AUTHENTIK_INSECURE}" == "true" ]]; then
    CURL_INSECURE_FLAG=("-k")
fi

echo "[INFO] Querying Authentik API (${AUTHENTIK_HOST}) for outpost '${OUTPOST_NAME}'..."
OUTPOST_JSON="$(curl -fsSL "${CURL_INSECURE_FLAG[@]}" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    "${AUTHENTIK_HOST}/api/v3/outposts/instances/?name=${OUTPOST_NAME}")"

TOKEN_KEY="$(python3 -c '
import json, sys, urllib.request, ssl
data = json.loads(sys.argv[1])
results = data.get("results", [])
if not results:
    sys.exit("Outpost not found yet (blueprint may still be applying)")
outpost_pk = results[0]["pk"]
host, api_token, insecure = sys.argv[2], sys.argv[3], sys.argv[4] == "true"
ctx = ssl._create_unverified_context() if insecure else ssl.create_default_context()
req = urllib.request.Request(
    f"{host}/api/v3/core/tokens/?identifier=ak-outpost-{outpost_pk}-api",
    headers={"Authorization": f"Bearer {api_token}"},
)
with urllib.request.urlopen(req, context=ctx) as resp:
    tok_list = json.loads(resp.read().decode())["results"]
if not tok_list:
    sys.exit("Outpost token object not found")
ident = tok_list[0]["identifier"]
req_view = urllib.request.Request(
    f"{host}/api/v3/core/tokens/{ident}/view_key/",
    headers={"Authorization": f"Bearer {api_token}"},
)
with urllib.request.urlopen(req_view, context=ctx) as resp:
    print(json.loads(resp.read().decode())["key"])
' "${OUTPOST_JSON}" "${AUTHENTIK_HOST}" "${API_TOKEN}" "${AUTHENTIK_INSECURE}")"

if [[ -z "${TOKEN_KEY}" ]]; then
    echo "[FAIL] Empty token returned from Authentik API." >&2
    exit 1
fi

python3 - "${ENV_FILE}" "${TOKEN_KEY}" <<'PY'
import os, re, sys
from pathlib import Path

env_path = Path(sys.argv[1])
new_token = sys.argv[2].strip()
text = env_path.read_text(encoding="utf-8")
updated = re.sub(
    r"^AUTHENTIK_OUTPOST_TOKEN=.*$",
    f"AUTHENTIK_OUTPOST_TOKEN={new_token}",
    text,
    flags=re.MULTILINE,
)
env_path.write_bytes(updated.replace("\r\n", "\n").encode("utf-8"))
if os.name == "posix":
    os.chmod(env_path, 0o600)
PY

echo "[OK] Updated AUTHENTIK_OUTPOST_TOKEN in ${ENV_FILE} (mode 0600)."
docker compose -f "${PROJECT_ROOT}/docker-compose.yml" -f "${PROJECT_ROOT}/docker-compose.hub.yml" up -d authentik-proxy
