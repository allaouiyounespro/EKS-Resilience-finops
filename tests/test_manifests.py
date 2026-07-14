"""Static checks on the Kubernetes manifests and the Grafana dashboard.

owner: allaouiyounespro
portfolio: github.com/allaouiyounespro

There is no cluster in CI, so `kubectl apply --dry-run=server` is not available.
That rules out schema validation - but it does NOT rule out checking the things
that actually go wrong in this repo, which are not schema errors:

  - a template placeholder shipped un-substituted
  - the witness Deployment losing the nodeSelector that keeps it off the system
    nodes, which would silently invalidate every experiment thereafter
  - the ServiceMonitor losing the release label, so Prometheus scrapes nothing
    and the dashboards are quietly empty
  - a PDB that can never be satisfied, which deadlocks Karpenter

Each of these produces a cluster that comes up green and an experiment that
measures the wrong thing. That is a far more dangerous class of bug than a typo
in an apiVersion, which fails loudly on the first apply.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

import yaml

REPO = Path(__file__).parent.parent
K8S = REPO / "k8s"


def load_all(path: Path) -> list[dict]:
    """Every document in a multi-document YAML file."""
    return [doc for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")) if doc]


def find_doc(docs: list[dict], kind: str) -> dict:
    for doc in docs:
        if doc.get("kind") == kind:
            return doc
    raise AssertionError(f"no {kind} in the document set")


class TestYamlParses(unittest.TestCase):
    def test_every_manifest_is_valid_yaml(self):
        manifests = sorted(K8S.rglob("*.yaml"))
        self.assertGreater(len(manifests), 0, "no manifests found - the glob is wrong")

        for path in manifests:
            with self.subTest(manifest=str(path.relative_to(REPO))):
                docs = load_all(path)
                self.assertGreater(len(docs), 0, "file parsed to nothing")

    def test_every_document_has_a_kind_and_an_apiversion(self):
        for path in sorted(K8S.rglob("*.yaml")):
            # values.yaml files are Helm inputs, not Kubernetes objects.
            if "values" in path.name:
                continue
            for doc in load_all(path):
                with self.subTest(manifest=path.name, kind=doc.get("kind")):
                    self.assertIn("apiVersion", doc)
                    self.assertIn("kind", doc)


class TestNoUnsubstitutedPlaceholders(unittest.TestCase):
    # Shell variables that legitimately appear as ${...} inside a container's
    # command, where they are expanded by the shell IN the container at runtime -
    # not by envsubst at deploy time. They are only safe because the bootstrap
    # script never pipes these files through envsubst, which is asserted below.
    SHELL_VARS_IN_CONTAINERS = {"${NODE_NAME}"}

    def test_envsubst_only_ever_touches_tpl_files(self):
        # The load-bearing invariant.
        #
        # envsubst replaces EVERY ${...} it sees, with an empty string if the
        # variable is unset. If anyone ever pipes 20-deployment.yaml through it,
        # the initContainer's ${NODE_NAME} silently becomes "", `kubectl get node
        # ""` fails, the zone file is empty, and every pod reports zone=unknown -
        # which quietly destroys the ability to tell "the survivors took over"
        # from "the doomed AZ answered again", i.e. the whole experiment.
        #
        # So: envsubst is allowed to read .tpl files and nothing else.
        bootstrap = (REPO / "scripts" / "bootstrap-cluster.sh").read_text(encoding="utf-8")

        # Only actual invocations - `envsubst < file` or `... | envsubst` - not the
        # dependency-check loop that merely names the binary.
        invocations = re.findall(r"^\s*(?:.*\|\s*)?envsubst\s*<[^<].*$", bootstrap, re.MULTILINE)
        self.assertGreater(len(invocations), 0, "the bootstrap script no longer renders any template")

        for line in invocations:
            with self.subTest(line=line.strip()):
                self.assertIn(
                    ".tpl", line,
                    "envsubst is being run on something that is not a .tpl template",
                )

    def test_applied_manifests_carry_no_stray_envsubst_placeholders(self):
        # .tpl files are rendered by envsubst and are SUPPOSED to contain ${...}.
        # Everything else is applied by kubectl (after a targeted sed), so the
        # only ${...} permitted is a shell variable the container itself expands.
        for path in sorted(K8S.rglob("*.yaml")):
            text = path.read_text(encoding="utf-8")

            residual = text
            for allowed in self.SHELL_VARS_IN_CONTAINERS:
                residual = residual.replace(allowed, "")

            with self.subTest(manifest=path.name):
                self.assertNotIn(
                    "${", residual,
                    "unrecognised ${...} in a manifest applied verbatim - if it is a shell "
                    "variable expanded inside the container, add it to SHELL_VARS_IN_CONTAINERS",
                )

    def test_the_deployment_placeholders_are_the_ones_bootstrap_replaces(self):
        text = (K8S / "workload" / "20-deployment.yaml").read_text(encoding="utf-8")
        bootstrap = (REPO / "scripts" / "bootstrap-cluster.sh").read_text(encoding="utf-8")

        # If someone renames a placeholder in the manifest and forgets the script,
        # the deploy fails at 3am with an ImagePullBackOff on an image literally
        # named "WITNESS_IMAGE".
        for placeholder in ("PLACEHOLDER_DB_HOST", "WITNESS_IMAGE"):
            self.assertIn(placeholder, text)
            self.assertIn(placeholder, bootstrap)


class TestWitnessDeployment(unittest.TestCase):
    def setUp(self):
        self.docs = load_all(K8S / "workload" / "20-deployment.yaml")
        self.deploy = find_doc(self.docs, "Deployment")
        self.spec = self.deploy["spec"]["template"]["spec"]

    def test_six_replicas(self):
        # Six divides cleanly by both 1 AZ and 3 AZs, so neither architecture
        # gets a rounding advantage. Changing this to 5 would hand infra-b an
        # uneven spread and a slightly unfair comparison.
        self.assertEqual(self.deploy["spec"]["replicas"], 6)

    def test_pods_are_pinned_to_karpenter_capacity(self):
        # THE most important assertion about the workload. If this selector is
        # lost, the pods schedule onto the pre-warmed managed node group, the
        # experiment never exercises Karpenter at all, and the RTO it reports is
        # meaningless - while everything still looks perfectly healthy.
        self.assertEqual(self.spec["nodeSelector"], {"karpenter.sh/nodepool": "witness"})

    def test_it_tolerates_the_nodepool_taint(self):
        # The NodePool taints its nodes so system workloads stay off them. If the
        # witness pods do not tolerate that taint, they are unschedulable
        # everywhere and the deploy hangs forever.
        taints = [(t.get("key"), t.get("value")) for t in self.spec["tolerations"]]
        self.assertIn(("workload", "app"), taints)

    def test_liveness_does_not_touch_the_database(self):
        # The single most consequential probe decision in the repo. A liveness
        # probe on /readyz would restart every pod simultaneously during an RDS
        # failover, converting a survivable event into a cluster-wide crash-loop
        # and inflating infra-b's RTO with entirely self-inflicted damage.
        container = next(c for c in self.spec["containers"] if c["name"] == "witness")
        self.assertEqual(container["livenessProbe"]["httpGet"]["path"], "/healthz")
        self.assertEqual(container["readinessProbe"]["httpGet"]["path"], "/readyz")

    def test_readiness_polls_fast_enough_to_measure_the_rto(self):
        # The readiness period is a floor on the measured RTO. At 10s, a tenth of
        # a 90-second recovery would be pure probe latency.
        container = next(c for c in self.spec["containers"] if c["name"] == "witness")
        self.assertLessEqual(container["readinessProbe"]["periodSeconds"], 3)

    def test_zone_spread_does_not_block_rescheduling_during_the_fault(self):
        # whenUnsatisfiable: DoNotSchedule on the zone key would refuse to place
        # replacement pods into the surviving AZs during the fault, because doing
        # so breaches the skew against the dead zone. The constraint would enforce
        # the very outage it exists to survive.
        zone_constraint = next(
            c for c in self.spec["topologySpreadConstraints"]
            if c["topologyKey"] == "topology.kubernetes.io/zone"
        )
        self.assertEqual(zone_constraint["whenUnsatisfiable"], "ScheduleAnyway")

    def test_no_cpu_limit(self):
        # A CPU limit would throttle the pod exactly while it is retrying
        # connections during a failover, adding latency to the recovery being
        # measured. Memory limit yes, CPU limit no.
        container = next(c for c in self.spec["containers"] if c["name"] == "witness")
        self.assertNotIn("cpu", container["resources"]["limits"])
        self.assertIn("memory", container["resources"]["limits"])


class TestPodDisruptionBudget(unittest.TestCase):
    def test_the_budget_is_satisfiable(self):
        # minAvailable must be strictly below the replica count. At minAvailable
        # == replicas, Karpenter can never drain a node, consolidation deadlocks,
        # and the cluster slowly fills with undrainable nodes. A PDB that cannot
        # be satisfied is an outage with a delayed fuse.
        pdb = find_doc(load_all(K8S / "workload" / "40-pdb.yaml"), "PodDisruptionBudget")
        deploy = find_doc(load_all(K8S / "workload" / "20-deployment.yaml"), "Deployment")

        min_available = pdb["spec"]["minAvailable"]
        replicas = deploy["spec"]["replicas"]

        self.assertLess(min_available, replicas)
        # And it must allow at least one AZ's worth (2 of 6) to be gone, or a
        # voluntary drain during recovery would be blocked.
        self.assertLessEqual(min_available, replicas - 2)

    def test_the_pdb_selector_matches_the_deployment(self):
        # A PDB whose selector matches nothing protects nothing, and reports no
        # error. It is the quietest possible way to have no disruption budget.
        pdb = find_doc(load_all(K8S / "workload" / "40-pdb.yaml"), "PodDisruptionBudget")
        deploy = find_doc(load_all(K8S / "workload" / "20-deployment.yaml"), "Deployment")

        self.assertEqual(
            pdb["spec"]["selector"]["matchLabels"],
            deploy["spec"]["selector"]["matchLabels"],
        )


class TestBootstrapAppliesEverything(unittest.TestCase):
    """Every manifest in k8s/ must be applied by the bootstrap script.

    This test exists because a manifest was written, applied by hand during a
    debugging session, and never added to the script. The next cluster came up
    without it. Nothing failed - the Karpenter ServiceMonitor was simply absent,
    so Karpenter was never scraped, so the "Karpenter nodes" panel was empty for
    an entire campaign, and the empty panel was indistinguishable from the finding
    it was supposed to prove.

    A file that exists in the repo but never reaches the cluster is worse than a
    file that does not exist, because everyone assumes it is doing its job.
    """

    def test_every_manifest_is_referenced_by_the_bootstrap(self):
        bootstrap = (REPO / "scripts" / "bootstrap-cluster.sh").read_text(encoding="utf-8")

        # .tpl files are rendered through envsubst and piped in, so they are
        # referenced by their template name. The dashboard JSON goes in as a
        # ConfigMap. Everything else is a plain kubectl apply -f.
        manifests = sorted(
            p for p in K8S.rglob("*.yaml")
            if "values" not in p.name  # Helm inputs, passed with --values
        )
        self.assertGreater(len(manifests), 0)

        for path in manifests:
            with self.subTest(manifest=path.name):
                self.assertIn(
                    path.name, bootstrap,
                    f"{path.relative_to(REPO)} exists but the bootstrap script never applies it - "
                    f"it will be silently absent from every cluster",
                )


class TestGateway(unittest.TestCase):
    """The Gateway API chain: GatewayClass -> Gateway -> HTTPRoute -> Service.

    Each link is a name reference the API server accepts unresolved - a typo in
    any of them produces a Gateway that exists, reports no error, and routes
    nothing. These tests walk the chain end to end so the typo fails in CI
    instead of as an addressless Gateway twenty minutes into a deploy.
    """

    def setUp(self):
        self.docs = load_all(K8S / "workload" / "30-gateway.yaml")

    def test_the_route_points_at_a_service_and_port_that_exist(self):
        route = find_doc(self.docs, "HTTPRoute")
        services = {d["metadata"]["name"]: d for d in self.docs if d["kind"] == "Service"}

        for rule in route["spec"]["rules"]:
            for backend in rule["backendRefs"]:
                with self.subTest(backend=backend["name"]):
                    self.assertIn(backend["name"], services)
                    ports = {p["port"] for p in services[backend["name"]]["spec"]["ports"]}
                    self.assertIn(backend["port"], ports)

    def test_the_route_attaches_to_the_gateway_defined_here(self):
        route = find_doc(self.docs, "HTTPRoute")
        gateway = find_doc(self.docs, "Gateway")

        parent_names = {p["name"] for p in route["spec"]["parentRefs"]}
        self.assertIn(gateway["metadata"]["name"], parent_names)

    def test_the_gateway_uses_the_gatewayclass_defined_here(self):
        gateway = find_doc(self.docs, "Gateway")
        gateway_class = find_doc(self.docs, "GatewayClass")

        self.assertEqual(gateway["spec"]["gatewayClassName"], gateway_class["metadata"]["name"])
        self.assertEqual(gateway_class["spec"]["controllerName"], "gateway.k8s.aws/alb")

    def test_the_gateway_does_not_accept_routes_from_other_namespaces(self):
        # A Gateway that accepts routes from anywhere lets any team attach paths
        # to this public hostname. "Same" is the entire multi-tenancy story.
        gateway = find_doc(self.docs, "Gateway")

        for listener in gateway["spec"]["listeners"]:
            self.assertEqual(listener["allowedRoutes"]["namespaces"]["from"], "Same")

    def test_health_checks_probe_readiness_not_liveness(self):
        # The ALB must ask /readyz. Pointed at /healthz, it would keep routing to
        # pods whose database is gone - /healthz answers 200 by design during an
        # RDS failover, and the availability measurement would read "up" while
        # every write failed.
        tg_config = find_doc(self.docs, "TargetGroupConfiguration")
        hc = tg_config["spec"]["defaultConfiguration"]["healthCheckConfig"]

        self.assertEqual(hc["healthCheckPath"], "/readyz")
        # The interval is RTO instrumentation: at 30s, a third of a 90-second
        # recovery would be load-balancer detection lag.
        self.assertLessEqual(hc["healthCheckInterval"], 10)

    def test_target_group_config_targets_the_routed_service(self):
        tg_config = find_doc(self.docs, "TargetGroupConfiguration")
        route = find_doc(self.docs, "HTTPRoute")

        routed = {b["name"] for rule in route["spec"]["rules"] for b in rule["backendRefs"]}
        self.assertIn(tg_config["spec"]["targetReference"]["name"], routed)


class TestNetworkPolicy(unittest.TestCase):
    def setUp(self):
        self.docs = load_all(K8S / "workload" / "50-networkpolicy.yaml")

    def test_a_default_deny_exists(self):
        deny = next(
            d for d in self.docs
            if d["kind"] == "NetworkPolicy" and d["spec"]["podSelector"] == {}
        )
        self.assertCountEqual(deny["spec"]["policyTypes"], ["Ingress", "Egress"])

    def test_the_allow_policy_permits_dns(self):
        # The single most common way a default-deny namespace dies: every
        # connection fails with a resolution timeout and nothing names the
        # NetworkPolicy. If someone edits the egress rules, this keeps port 53.
        allow = find_doc([d for d in self.docs if d["metadata"]["name"] == "witness-allow"], "NetworkPolicy")

        dns_ports = {
            (p["protocol"], p["port"])
            for rule in allow["spec"]["egress"]
            for p in rule.get("ports", [])
            if p["port"] == 53
        }
        self.assertIn(("UDP", 53), dns_ports)

    def test_the_allow_policy_permits_postgres_egress(self):
        allow = find_doc([d for d in self.docs if d["metadata"]["name"] == "witness-allow"], "NetworkPolicy")

        ports = {
            p["port"]
            for rule in allow["spec"]["egress"]
            for p in rule.get("ports", [])
        }
        self.assertIn(5432, ports)


class TestMonitoring(unittest.TestCase):
    def test_servicemonitor_carries_the_release_label(self):
        # Without this label the kube-prometheus-stack Prometheus does not adopt
        # the ServiceMonitor. Nothing errors; the metrics simply never arrive and
        # every dashboard is empty. It is the single most common Prometheus
        # Operator footgun.
        sm = find_doc(load_all(K8S / "monitoring" / "servicemonitor-witness.yaml"), "ServiceMonitor")
        self.assertEqual(sm["metadata"]["labels"].get("release"), "kube-prometheus-stack")

    def test_servicemonitor_targets_the_headless_service(self):
        sm = find_doc(load_all(K8S / "monitoring" / "servicemonitor-witness.yaml"), "ServiceMonitor")
        services = load_all(K8S / "workload" / "30-gateway.yaml")

        metrics_svc = next(s for s in services if s["metadata"]["name"] == "witness-metrics")
        port_names = {p["name"] for p in metrics_svc["spec"]["ports"]}

        for endpoint in sm["spec"]["endpoints"]:
            self.assertIn(endpoint["port"], port_names)

    def test_prometheus_rules_parse_and_are_named(self):
        rule = find_doc(load_all(K8S / "monitoring" / "prometheusrule-resilience.yaml"), "PrometheusRule")
        groups = rule["spec"]["groups"]
        self.assertGreater(len(groups), 0)

        for group in groups:
            for r in group["rules"]:
                with self.subTest(group=group["name"]):
                    # Every rule is either a recording rule or an alert. One that
                    # is neither is a typo that Prometheus rejects at load time,
                    # taking the whole ruleset down with it.
                    self.assertTrue(
                        ("record" in r) or ("alert" in r),
                        f"rule in {group['name']} is neither a record nor an alert",
                    )
                    self.assertIn("expr", r)

    def test_the_alerts_reference_recording_rules_that_exist(self):
        # An alert whose expression names a recording rule that was renamed will
        # evaluate to nothing forever and never fire. Silently.
        rule = find_doc(load_all(K8S / "monitoring" / "prometheusrule-resilience.yaml"), "PrometheusRule")

        recorded = {
            r["record"]
            for group in rule["spec"]["groups"]
            for r in group["rules"]
            if "record" in r
        }
        alerts = [
            r for group in rule["spec"]["groups"] for r in group["rules"] if "alert" in r
        ]

        self.assertGreater(len(alerts), 0)

        for alert in alerts:
            expr = alert["expr"]
            # Recording-rule names in this repo all carry a colon, per Prometheus
            # convention. Pull them out of the expression and check they exist.
            referenced = {
                token.strip("()")
                for token in expr.replace("\n", " ").split()
                if ":" in token and not token.startswith("http")
            }
            for name in referenced:
                if name.count(":") >= 2:  # our naming convention: level:metric:operation
                    with self.subTest(alert=alert["alert"], rule=name):
                        self.assertIn(name, recorded, f"{alert['alert']} references an unknown recording rule")


class TestGrafanaDashboard(unittest.TestCase):
    def setUp(self):
        path = K8S / "monitoring" / "grafana-dashboard-resilience.json"
        self.dashboard = json.loads(path.read_text(encoding="utf-8"))

    def test_it_is_valid_json_with_the_required_fields(self):
        self.assertIn("panels", self.dashboard)
        self.assertIn("uid", self.dashboard)
        self.assertGreater(len(self.dashboard["panels"]), 0)

    def test_every_panel_queries_a_recording_rule_that_exists(self):
        # A dashboard panel pointing at a metric that no rule produces renders an
        # empty graph, which reads as "the system is fine" rather than "this panel
        # is broken". During an incident that is a genuinely dangerous ambiguity.
        rule = find_doc(load_all(K8S / "monitoring" / "prometheusrule-resilience.yaml"), "PrometheusRule")
        recorded = {
            r["record"]
            for group in rule["spec"]["groups"]
            for r in group["rules"]
            if "record" in r
        }

        for panel in self.dashboard["panels"]:
            for target in panel.get("targets", []):
                expr = target.get("expr", "")
                if expr.count(":") >= 2:
                    with self.subTest(panel=panel.get("title")):
                        self.assertIn(expr, recorded, f"panel {panel.get('title')!r} queries an unknown rule")

    def test_no_panel_uses_a_second_y_axis(self):
        # A dual-axis chart lets any two series be made to look correlated by
        # choosing the scales. It is the most reliable way to mislead with a
        # dashboard, and it is banned here.
        for panel in self.dashboard["panels"]:
            overrides = panel.get("fieldConfig", {}).get("overrides", [])
            for override in overrides:
                for prop in override.get("properties", []):
                    with self.subTest(panel=panel.get("title")):
                        self.assertNotEqual(
                            prop.get("id"), "custom.axisPlacement",
                            "second y-axis detected",
                        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
