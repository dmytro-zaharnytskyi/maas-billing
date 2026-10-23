"""E2E: external models outside tenant namespaces, served by the default tenant.

RHOAIENG-101754 (3.5 → 3.6 compatibility). In 3.5 the default tenant served
ExternalModels in every namespace. With ai-gateway-controller (AGC) on the
Praxis dataplane, an ExternalModel without gatewayRefs in a namespace that has
no MaasTenantConfig and that no AITenant claims is served by the default
tenant (AITenant models-as-a-service) as an implicit attachment to its
Gateway: the same hashed HTTPRoute, DestinationRule and credential copy as an
explicit gatewayRefs attachment, with spec unchanged.

The models live in MODEL_NAMESPACE (llm): the namespace 3.5 demos used, and
one the default Gateway's allowedRoutes already admits (a fresh user
namespace would need the default Gateway patched). The stack is 3.5-shaped:
the provider uses ``auth.type: simple``, which the AGC serves as ``apikey``.
The provider endpoint is a header-echo service (default httpbingo.org): under
``/anything/<tag>`` it echoes the request, so a response proves which binding
served it and which credential was injected.

Scenarios:
- The model and its provider reach Ready and serve inference through the
  default Gateway, with the credential delivered as a copy into the default
  tenant namespace.
- gatewayRefs replace the implicit attachment and remove its objects, without
  falling back to the default Gateway; removing them restores it.
- Deleting the model removes the implicit attachment's objects.

Skips unless the AGC is installed and the default tenant runs praxis-extproc:
a default tenant on IPP serves these models itself and the AGC leaves them
alone.

Environment variables:
- E2E_EXTERNAL_ENDPOINT: header-echo endpoint FQDN (default: httpbingo.org)
- E2E_TENANT_EXTERNAL_MODEL_READY_TIMEOUT: wait for AGC reconciliation (default: 300)
- AGC_DEPLOYMENT_NAME / AGC_DEPLOYMENT_NAMESPACE: the ai-gateway-controller
  Deployment (defaults: "ai-gateway-controller" in DEPLOYMENT_NAMESPACE)
"""

from __future__ import annotations

import base64
import json
import logging
import os
import re
import time
import uuid

import pytest
import requests
from multitenancy_helpers import (
    AITENANT_KIND,
    AITENANT_NAMESPACE,
    DEFAULT_AITENANT_NAME,
    DEFAULT_GATEWAY_NAME,
    GATEWAY_NAMESPACE,
    TENANT_CONFIG_KIND,
    TENANT_CR_NAME,
    _oc_run,
    apply_maas_auth_policy,
    apply_maas_subscription,
    create_api_key_at,
    extproc_deployment_uses_praxis,
    get_json_or_none,
    list_json,
    redact_sensitive,
    wait_for_status_phase,
    wait_until,
)
from test_helper import (
    DEPLOYMENT_NAMESPACE,
    MODEL_NAMESPACE,
    TLS_VERIFY,
    _apply_cr,
    _delete_cr,
    _get_cluster_token,
    _get_cr,
    _ns,
    _wait_for_gateway_auth_enforced,
    _wait_for_model_ready,
    _wait_for_subscription_trlp_status,
)

log = logging.getLogger(__name__)

# Serialized with tenant_ipp, which runs legacy IPP tenant stacks: those must
# not run next to this suite's models.
pytestmark = pytest.mark.xdist_group("tenant_ipp")

EXTERNAL_MODEL_CRD = "externalmodels.inference.opendatahub.io"
EXTERNAL_MODEL_KIND = "externalmodels.inference.opendatahub.io"
EXTERNAL_PROVIDER_KIND = "externalproviders.inference.opendatahub.io"
INFERENCE_API_VERSION = "inference.opendatahub.io/v1alpha1"

EXTERNAL_ENDPOINT = os.environ.get("E2E_EXTERNAL_ENDPOINT", "httpbingo.org")
READY_TIMEOUT = int(os.environ.get("E2E_TENANT_EXTERNAL_MODEL_READY_TIMEOUT", "300"))
AGC_DEPLOYMENT_NAME = os.environ.get("AGC_DEPLOYMENT_NAME", "ai-gateway-controller")
AGC_DEPLOYMENT_NAMESPACE = os.environ.get("AGC_DEPLOYMENT_NAMESPACE", DEPLOYMENT_NAMESPACE)

# A Gateway no AITenant manages (it need not exist): an explicit binding to it
# is refused with GatewayNotManaged.
UNMANAGED_GATEWAY_NAME = "e2e-dft-unmanaged-gateway"

# AGC attachment routes are named external-model-<model>-<12-hex hash of
# model namespace/name and Gateway namespace/name>.
ATTACHMENT_ROUTE_HASH_RE = re.compile(r"[0-9a-f]{12}")

# AGC labels on the Gateway-namespace provider DestinationRules.
LABEL_EXTERNAL_PROVIDER = "inference.opendatahub.io/external-provider"
LABEL_EXTERNAL_GATEWAY = "inference.opendatahub.io/external-gateway"


# ─── Preconditions ──────────────────────────────────────────────────────────


def _require_agc_support() -> None:
    """Skip unless the installed ExternalModel CRD and AGC serve attachments."""
    crd = get_json_or_none("crd", EXTERNAL_MODEL_CRD)
    if crd is None:
        pytest.skip(f"ExternalModel CRD {EXTERNAL_MODEL_CRD} is not installed")
    spec_props: dict = {}
    status_props: dict = {}
    for version in (crd.get("spec") or {}).get("versions") or []:
        props = ((version.get("schema") or {}).get("openAPIV3Schema") or {}).get("properties") or {}
        spec_props.update((props.get("spec") or {}).get("properties") or {})
        status_props.update((props.get("status") or {}).get("properties") or {})
    if "gatewayRefs" not in spec_props or "gateways" not in status_props:
        pytest.skip("installed ExternalModel CRD lacks the gatewayRefs / status.gateways schema")
    if get_json_or_none("deployment", AGC_DEPLOYMENT_NAME, AGC_DEPLOYMENT_NAMESPACE) is None:
        message = f"ai-gateway-controller deployment {AGC_DEPLOYMENT_NAMESPACE}/{AGC_DEPLOYMENT_NAME} not found"
        # The prow smoke path deploys AGC whenever this is set: a missing
        # deployment there is a failed deploy, not a cluster without AGC.
        if os.environ.get("AI_GATEWAY_CONTROLLER_IMAGE"):
            pytest.fail(message)
        pytest.skip(message)


@pytest.fixture(scope="module")
def default_tenant(gateway_url, maas_api_base_url):
    """The default tenant's namespace, Gateway and URLs, once the scenario applies."""
    _require_agc_support()
    if not extproc_deployment_uses_praxis("payload-processing", GATEWAY_NAMESPACE):
        pytest.skip(
            "default tenant payload-processing is not praxis-extproc; its IPP serves "
            "models without gatewayRefs and the AGC leaves them alone"
        )
    aitenant = get_json_or_none(AITENANT_KIND, DEFAULT_AITENANT_NAME, AITENANT_NAMESPACE) or {}
    aitenant_status = aitenant.get("status") or {}
    gateway = aitenant_status.get("gatewayRef") or {}
    if gateway != {"name": DEFAULT_GATEWAY_NAME, "namespace": GATEWAY_NAMESPACE}:
        pytest.skip(
            f"default AITenant {AITENANT_NAMESPACE}/{DEFAULT_AITENANT_NAME} publishes Gateway "
            f"{gateway or '<none>'}, not {GATEWAY_NAMESPACE}/{DEFAULT_GATEWAY_NAME}"
        )
    if get_json_or_none(TENANT_CONFIG_KIND, TENANT_CR_NAME, MODEL_NAMESPACE) is not None:
        pytest.skip(f"{MODEL_NAMESPACE} has a MaasTenantConfig; its own tenant serves its models")
    return {
        "tenant_ns": aitenant_status.get("tenantNamespace") or _ns(),
        "gateway_name": DEFAULT_GATEWAY_NAME,
        "gateway_url": gateway_url,
        "maas_api_url": maas_api_base_url,
    }


# ─── Resources ──────────────────────────────────────────────────────────────


class _Resources:
    """Delete tracked objects in reverse creation order."""

    def __init__(self):
        self._items: list[tuple[str, str, str]] = []

    def track(self, kind: str, name: str, namespace: str) -> None:
        self._items.append((kind, name, namespace))

    def cleanup(self) -> None:
        for kind, name, namespace in reversed(self._items):
            try:
                if kind == "maasmodelref":
                    # Never hang on the MaaSModelRef cleanup handshake.
                    _oc_run(
                        ["patch", kind, name, "-n", namespace, "--type=merge", "-p", '{"metadata":{"finalizers":[]}}']
                    )
                _delete_cr(kind, name, namespace)
            except Exception as exc:  # noqa: BLE001 - one failed item must not abort the rest
                log.warning("cleanup failed for %s/%s in %s: %s", kind, name, namespace, exc)


@pytest.fixture
def resources():
    tracked = _Resources()
    try:
        yield tracked
    finally:
        tracked.cleanup()


def _provision_model(tracked: _Resources, prefix: str) -> dict:
    """A 3.5-shaped stack in MODEL_NAMESPACE: credential Secret, provider with
    ``auth.type: simple``, ExternalModel without gatewayRefs and its MaaSModelRef."""
    suffix = uuid.uuid4().hex[:6]
    name = f"{prefix}-{suffix}"
    model = {
        "name": name,
        "namespace": MODEL_NAMESPACE,
        "provider": f"{name}-provider",
        "secret_name": f"{name}-cred",
        "credential": f"sk-extmod-{suffix}",
        "path_tag": f"{name}-{uuid.uuid4().hex[:6]}",
    }
    _apply_cr(
        {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {
                "name": model["secret_name"],
                "namespace": MODEL_NAMESPACE,
                "labels": {"inference.llm-d.ai/ipp-managed": "true"},
            },
            "type": "Opaque",
            "stringData": {"api-key": model["credential"]},
        }
    )
    tracked.track("secret", model["secret_name"], MODEL_NAMESPACE)
    _apply_cr(
        {
            "apiVersion": INFERENCE_API_VERSION,
            "kind": "ExternalProvider",
            "metadata": {"name": model["provider"], "namespace": MODEL_NAMESPACE},
            "spec": {
                "provider": "openai",
                "endpoint": EXTERNAL_ENDPOINT,
                "auth": {"type": "simple", "secretRef": {"name": model["secret_name"]}},
            },
        }
    )
    tracked.track(EXTERNAL_PROVIDER_KIND, model["provider"], MODEL_NAMESPACE)
    _apply_cr(
        {
            "apiVersion": INFERENCE_API_VERSION,
            "kind": "ExternalModel",
            "metadata": {"name": name, "namespace": MODEL_NAMESPACE},
            "spec": {
                "externalProviderRefs": [
                    {
                        "ref": {"name": model["provider"]},
                        "targetModel": "gpt-3.5-turbo",
                        "apiFormat": "openai-chat",
                        "path": f"/anything/{model['path_tag']}",
                    }
                ],
            },
        }
    )
    tracked.track(EXTERNAL_MODEL_KIND, name, MODEL_NAMESPACE)
    _apply_cr(
        {
            "apiVersion": "maas.opendatahub.io/v1alpha1",
            "kind": "MaaSModelRef",
            "metadata": {
                "name": name,
                "namespace": MODEL_NAMESPACE,
                "annotations": {
                    "maas.opendatahub.io/endpoint": EXTERNAL_ENDPOINT,
                    "maas.opendatahub.io/provider": "openai",
                },
            },
            "spec": {"modelRef": {"kind": "ExternalModel", "name": name}},
        }
    )
    tracked.track("maasmodelref", name, MODEL_NAMESPACE)
    return model


def _patch_gateway_refs(model: dict, gateway_refs: list[dict] | None) -> None:
    result = _oc_run(
        [
            "patch",
            EXTERNAL_MODEL_KIND,
            model["name"],
            "-n",
            model["namespace"],
            "--type=merge",
            "-p",
            json.dumps({"spec": {"gatewayRefs": gateway_refs}}),
        ]
    )
    if result.returncode != 0:
        raise RuntimeError(f"failed to patch gatewayRefs on {model['name']}: {result.stderr.strip()}")


# ─── Attachment state ───────────────────────────────────────────────────────


def _gateway_result(model: dict, gateway_name: str) -> dict | None:
    """The model's status.gateways result for one Gateway."""
    external_model = get_json_or_none(EXTERNAL_MODEL_KIND, model["name"], model["namespace"]) or {}
    for entry in (external_model.get("status") or {}).get("gateways") or []:
        if entry.get("name") == gateway_name and entry.get("namespace") == GATEWAY_NAMESPACE:
            return entry
    return None


def _wait_gateway_result(model: dict, gateway_name: str, *, reason: str | None = None) -> dict:
    """Wait for a Ready result for one Gateway, or a not-Ready one with *reason*."""

    def _check() -> dict:
        entry = _gateway_result(model, gateway_name)
        ready = next((c for c in (entry or {}).get("conditions") or [] if c.get("type") == "Ready"), {})
        if reason is None:
            assert ready.get("status") == "True", f"no Ready result for {gateway_name}: {redact_sensitive(entry)}"
        else:
            assert ready.get("status") == "False" and ready.get("reason") == reason, (
                f"no {reason} result for {gateway_name}: {redact_sensitive(entry)}"
            )
        return entry

    return wait_until(_check, READY_TIMEOUT, f"{model['name']} result for {gateway_name} ({reason or 'Ready'})")


def _attachment_routes(model: dict, gateway_name: str) -> list[dict]:
    """The model's AGC attachment HTTPRoutes whose parentRefs select the Gateway."""
    prefix = f"external-model-{model['name']}-"
    routes = []
    for route in list_json("httproute", model["namespace"]):
        route_name = (route.get("metadata") or {}).get("name") or ""
        if not (route_name.startswith(prefix) and ATTACHMENT_ROUTE_HASH_RE.fullmatch(route_name[len(prefix):])):
            continue
        if any(
            parent.get("name") == gateway_name and (parent.get("namespace") or GATEWAY_NAMESPACE) == GATEWAY_NAMESPACE
            for parent in (route.get("spec") or {}).get("parentRefs") or []
        ):
            routes.append(route)
    return routes


def _route_accepted(route: dict, gateway_name: str) -> bool:
    for parent in (route.get("status") or {}).get("parents") or []:
        ref = parent.get("parentRef") or {}
        if ref.get("name") == gateway_name:
            return any(
                c.get("type") == "Accepted" and c.get("status") == "True" for c in parent.get("conditions") or []
            )
    return False


def _credential_copies(tenant_ns: str, model: dict) -> list[dict]:
    """Secrets in the tenant namespace carrying the model's credential."""
    encoded = base64.b64encode(model["credential"].encode()).decode()
    return [s for s in list_json("secret", tenant_ns) if (s.get("data") or {}).get("api-key") == encoded]


def _destination_rules(model: dict, gateway_name: str) -> list[dict]:
    return list_json(
        "destinationrule",
        GATEWAY_NAMESPACE,
        labels=f"{LABEL_EXTERNAL_PROVIDER}={model['provider']},{LABEL_EXTERNAL_GATEWAY}={gateway_name}",
    )


def _wait_implicitly_attached(default_tenant: dict, model: dict) -> dict:
    """Wait for the implicit attachment's result, accepted route, credential
    copy and DestinationRule; returns the result and route."""
    gateway = default_tenant["gateway_name"]
    entry = _wait_gateway_result(model, gateway)

    def _route() -> dict:
        routes = _attachment_routes(model, gateway)
        assert len(routes) == 1 and _route_accepted(routes[0], gateway), (
            f"expected one accepted attachment route on {gateway}: {[r.get('status') for r in routes]}"
        )
        return routes[0]

    route = wait_until(_route, READY_TIMEOUT, f"attachment route for {model['name']} on {gateway}")

    # Published only after the Gateway accepts the route.
    def _published() -> bool:
        assert _credential_copies(default_tenant["tenant_ns"], model), (
            f"no credential copy for {model['name']} in {default_tenant['tenant_ns']}"
        )
        assert _destination_rules(model, gateway), (
            f"no DestinationRule for {model['provider']} on {gateway} in {GATEWAY_NAMESPACE}"
        )
        return True

    wait_until(_published, READY_TIMEOUT, f"credential copy and DestinationRule for {model['name']}")
    return {"result": entry, "route": route}


def _wait_not_implicitly_attached(default_tenant: dict, model: dict) -> None:
    """Wait until the implicit attachment and every object it published are gone."""
    gateway = default_tenant["gateway_name"]

    def _gone() -> bool:
        assert _gateway_result(model, gateway) is None, f"{model['name']} still reports a result for {gateway}"
        assert not _attachment_routes(model, gateway), f"{model['name']} still has a route on {gateway}"
        assert not _credential_copies(default_tenant["tenant_ns"], model), (
            f"credential copy for {model['name']} still in {default_tenant['tenant_ns']}"
        )
        assert not _destination_rules(model, gateway), f"DestinationRule for {model['provider']} still present"
        return True

    wait_until(_gone, READY_TIMEOUT, f"removal of {model['name']}'s implicit attachment")


# ─── Serving ────────────────────────────────────────────────────────────────


def _serve_in_default_tenant(tracked: _Resources, default_tenant: dict, model: dict) -> str:
    """MaaSAuthPolicy + MaaSSubscription in the default tenant; returns an API key."""
    tenant_ns = default_tenant["tenant_ns"]
    policy, subscription = f"{model['name']}-access", f"{model['name']}-sub"
    apply_maas_auth_policy(policy, tenant_ns, model_ref=model["name"], model_namespace=model["namespace"])
    tracked.track("maasauthpolicy", policy, tenant_ns)
    wait_for_status_phase("maasauthpolicy", policy, tenant_ns, expected_phase="Active", timeout=READY_TIMEOUT)
    _wait_for_gateway_auth_enforced()
    apply_maas_subscription(subscription, tenant_ns, model_ref=model["name"], model_namespace=model["namespace"])
    tracked.track("maassubscription", subscription, tenant_ns)
    wait_for_status_phase(
        "maassubscription", subscription, tenant_ns, expected_phase=("Active", "Degraded"), timeout=READY_TIMEOUT
    )
    _wait_for_subscription_trlp_status(subscription, expected_ready=True, namespace=tenant_ns, timeout=READY_TIMEOUT)
    _wait_for_model_ready(model["name"], model["namespace"], timeout=READY_TIMEOUT)
    response = create_api_key_at(
        default_tenant["maas_api_url"],
        _get_cluster_token(),
        f"e2e-dft-{uuid.uuid4().hex[:8]}",
        subscription=subscription,
    )
    assert response.status_code in (200, 201), (
        f"failed to mint an API key: {response.status_code} {redact_sensitive(response.text)}"
    )
    return response.json()["key"]


def _infer(gateway_url: str, model: dict, api_key: str, *, retries: int = 6, delay: int = 5) -> requests.Response:
    """POST a chat completion to the model's echo path, retrying route
    propagation (404) and transient gateway responses."""
    url = f"{gateway_url.rstrip('/')}/{model['namespace']}/{model['name']}/anything/{model['path_tag']}"
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    body = {"model": model["name"], "messages": [{"role": "user", "content": "default tenant e2e"}], "max_tokens": 8}
    response = None
    for attempt in range(1, retries + 1):
        response = requests.post(url, headers=headers, json=body, timeout=45, verify=TLS_VERIFY)
        text = (response.text or "").strip()
        transient = (
            response.status_code == 404
            or (response.status_code in (401, 403) and not text)
            or (response.status_code in (500, 503) and (not text or "AUTH_FAILURE" in text))
        )
        if response.status_code == 200 or not transient or attempt == retries:
            return response
        log.info("inference got %d (attempt %d/%d), retrying", response.status_code, attempt, retries)
        time.sleep(delay)
    return response


# ─── Serving through the default Gateway ────────────────────────────────────


class TestDefaultTenantServesModelWithoutGatewayRefs:
    """A 3.5-shaped model in a namespace of no tenant is served through the
    default tenant's Gateway."""

    @pytest.fixture(scope="class")
    def implicit_model(self, default_tenant):
        tracked = _Resources()
        try:
            model = _provision_model(tracked, "e2e-dft")
            attachment = _wait_implicitly_attached(default_tenant, model)
            api_key = _serve_in_default_tenant(tracked, default_tenant, model)
            yield {"model": model, "api_key": api_key, **attachment}
        finally:
            tracked.cleanup()

    def test_attached_to_default_gateway(self, implicit_model):
        """One Ready result for the default Gateway names the attachment
        route, and the spec still names no Gateway."""
        model = implicit_model["model"]
        route_name = implicit_model["route"]["metadata"]["name"]
        external_model = get_json_or_none(EXTERNAL_MODEL_KIND, model["name"], model["namespace"]) or {}
        spec = external_model.get("spec") or {}
        assert not spec.get("gatewayRefs"), f"the implicit attachment must not mutate spec: {spec}"
        status = external_model.get("status") or {}
        results = [(entry.get("namespace"), entry.get("name")) for entry in status.get("gateways") or []]
        assert results == [(GATEWAY_NAMESPACE, DEFAULT_GATEWAY_NAME)], f"unexpected status.gateways: {results}"
        route_ref = implicit_model["result"].get("httpRouteRef") or {}
        assert (route_ref.get("namespace"), route_ref.get("name")) == (model["namespace"], route_name), (
            f"status.gateways httpRouteRef {route_ref} does not name the attachment route {route_name}"
        )
        assert status.get("httpRouteName") == route_name, (
            f"status.httpRouteName {status.get('httpRouteName')!r} must name the single attachment "
            f"route {route_name} (maas-controller resolves the model's route from it)"
        )

    def test_provider_reports_ready(self, implicit_model):
        """The provider reports its own validated configuration instead of
        Pending on the namespace's missing MaasTenantConfig."""
        model = implicit_model["model"]

        def _check() -> bool:
            provider = get_json_or_none(EXTERNAL_PROVIDER_KIND, model["provider"], model["namespace"]) or {}
            status = provider.get("status") or {}
            ready = next((c for c in status.get("conditions") or [] if c.get("type") == "Ready"), {})
            assert status.get("phase") == "Ready" and ready.get("status") == "True", (
                f"provider {model['provider']} is not Ready: {redact_sensitive(status)}"
            )
            return True

        wait_until(_check, READY_TIMEOUT, f"provider {model['provider']} Ready")

    def test_served_through_default_gateway(self, default_tenant, implicit_model):
        """Inference through the default Gateway reaches the provider with the
        model's credential injected (``simple`` auth served as ``apikey``)."""
        model = implicit_model["model"]
        response = _infer(default_tenant["gateway_url"], model, implicit_model["api_key"])
        assert response.status_code == 200, (
            f"expected 200 through {DEFAULT_GATEWAY_NAME}, got {response.status_code}: "
            f"{redact_sensitive(response.text)}"
        )
        assert model["path_tag"] in response.text, f"response did not come from the model's provider: {response.text}"
        assert model["credential"] in response.text, "the model's credential did not reach the provider"

    def test_unknown_key_rejected(self, default_tenant, implicit_model):
        model = implicit_model["model"]
        response = _infer(default_tenant["gateway_url"], model, f"sk-extmod-invalid-{uuid.uuid4().hex[:8]}", retries=1)
        assert response.status_code in (401, 403), (
            f"unknown API key must be rejected, got {response.status_code}: {redact_sensitive(response.text)}"
        )


# ─── Implicit attachment lifecycle ──────────────────────────────────────────


class TestImplicitAttachmentLifecycle:
    """gatewayRefs replace the implicit attachment and removing them restores
    it; deleting the model removes its objects."""

    def test_gateway_refs_replace_implicit_attachment(self, default_tenant, resources):
        """An explicit binding replaces the implicit one and never falls back
        to the default Gateway, even when no tenant can serve it."""
        model = _provision_model(resources, "e2e-dft-refs")
        _wait_implicitly_attached(default_tenant, model)

        _patch_gateway_refs(model, [{"name": UNMANAGED_GATEWAY_NAME, "namespace": GATEWAY_NAMESPACE}])
        _wait_gateway_result(model, UNMANAGED_GATEWAY_NAME, reason="GatewayNotManaged")
        _wait_not_implicitly_attached(default_tenant, model)

        _patch_gateway_refs(model, None)
        _wait_implicitly_attached(default_tenant, model)
        assert _gateway_result(model, UNMANAGED_GATEWAY_NAME) is None, (
            f"removing gatewayRefs must drop the {UNMANAGED_GATEWAY_NAME} result"
        )

    def test_model_delete_removes_implicit_attachment(self, default_tenant, resources):
        model = _provision_model(resources, "e2e-dft-del")
        _wait_implicitly_attached(default_tenant, model)

        _delete_cr("maasmodelref", model["name"], model["namespace"])
        _delete_cr(EXTERNAL_MODEL_KIND, model["name"], model["namespace"])

        def _deleted() -> bool:
            assert _get_cr(EXTERNAL_MODEL_KIND, model["name"], model["namespace"]) is None, (
                f"{model['name']} still exists (attachment cleanup finalizer)"
            )
            assert not _attachment_routes(model, default_tenant["gateway_name"]), "attachment route not removed"
            assert not _credential_copies(default_tenant["tenant_ns"], model), "credential copy not removed"
            assert not _destination_rules(model, default_tenant["gateway_name"]), "DestinationRule not removed"
            return True

        wait_until(_deleted, READY_TIMEOUT, f"deletion of {model['name']} and its attachment objects")
