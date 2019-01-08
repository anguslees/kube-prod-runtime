/*
 * Bitnami Kubernetes Production Runtime - A collection of services that makes it
 * easy to run production workloads in Kubernetes.
 *
 * Copyright 2018-2019 Bitnami
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

local kube = import "../lib/kube.libsonnet";
local CERT_MANAGER_IMAGE = (import "images.json")["cert-manager"];
local CERT_MANAGER_WEBHOOK_IMAGE = (import "images.json")["cert-manager-webhook"];

// TODO(gus): move to kube.libsonnet
local APIService(group, version) = {
  local this = self,
  service_:: error "service_ is required",

  apiVersion: "apiregistration.k8s.io/v1beta1",
  kind: "APIService",
  metadata+: {
    name: "%s.%s" % [this.spec.version, this.spec.group],
  },
  spec+: {
    group: group,
    version: version,
    service: {
      namespace: this.service_.metadata.namespace,
      name: this.service_.metadata.name,
    },
    // arbitrary conservative default priorities
    groupPriorityMinimum: 1000,
    versionPriority: 15,
  },
};

// TODO(gus): move to kube.libsonnet
local ValidatingWebhookConfiguration(name) = kube._Object("admissionregistration.k8s.io/v1beta1", "ValidatingWebhookConfiguration", name) {
  webhooks: [],
};

{
  p:: "",
  metadata:: {
    metadata+: {
      namespace: "kubeprod",
    },
  },
  letsencrypt_contact_email:: error "Letsencrypt contact e-mail is undefined",

  // Letsencrypt environments
  letsencrypt_environments:: {
    "prod": $.letsencryptProd.metadata.name,
    "staging": $.letsencryptStaging.metadata.name,
  },
  // Letsencrypt environment (defaults to the production one)
  letsencrypt_environment:: "prod",

  Issuer(name):: kube._Object("certmanager.k8s.io/v1alpha1", "Issuer", name) {
  },

  ClusterIssuer(name):: kube._Object("certmanager.k8s.io/v1alpha1", "ClusterIssuer", name) {
  },

  Certificate(name):: kube._Object("certmanager.k8s.io/v1alpha1", "Certificate", name) {
  },

  certCRD: kube.CustomResourceDefinition("certmanager.k8s.io", "v1alpha1", "Certificate") {
    spec+: { names+: { shortNames+: ["cert", "certs"] } },
  },

  issuerCRD: kube.CustomResourceDefinition("certmanager.k8s.io", "v1alpha1", "Issuer"),

  clusterissuerCRD: kube.CustomResourceDefinition("certmanager.k8s.io", "v1alpha1", "ClusterIssuer") {
    spec+: {
      scope: "Cluster",
    },
  },

  sa: kube.ServiceAccount($.p + "cert-manager") + $.metadata {
  },

  clusterRole: kube.ClusterRole($.p + "cert-manager") {
    rules: [
      {
        apiGroups: ["certmanager.k8s.io"],
        resources: ["certificates", "issuers", "clusterissuers"],
        // FIXME: audit - the helm chart just has "*"
        verbs: ["get", "list", "watch", "create", "patch", "update", "delete"],
      },
      {
        apiGroups: [""],
        resources: ["secrets", "configmaps", "services", "pods"],
        // FIXME: audit - the helm chart just has "*"
        verbs: ["get", "list", "watch", "create", "patch", "update", "delete"],
      },
      {
        apiGroups: ["extensions"],
        resources: ["ingresses"],
        // FIXME: audit - the helm chart just has "*"
        verbs: ["get", "list", "watch", "create", "patch", "update", "delete"],
      },
      {
        apiGroups: [""],
        resources: ["events"],
        verbs: ["create", "patch", "update"],
      },
    ],
  },

  clusterRoleBinding: kube.ClusterRoleBinding($.p+"cert-manager") {
    roleRef_: $.clusterRole,
    subjects_+: [$.sa],
  },

  deploy: kube.Deployment($.p+"cert-manager") + $.metadata {
    spec+: {
      template+: {
        metadata+: {
          annotations+: {
            "prometheus.io/scrape": "true",
            "prometheus.io/port": "9402",
            "prometheus.io/path": "/metrics",
          },
        },
        spec+: {
          serviceAccountName: $.sa.metadata.name,
          containers_+: {
            default: kube.Container("cert-manager") {
              image: CERT_MANAGER_IMAGE,
              args_+: {
                "cluster-resource-namespace": "$(POD_NAMESPACE)",
                "leader-election-namespace": "$(POD_NAMESPACE)",
                "default-issuer-name": $.letsencrypt_environments[$.letsencrypt_environment],
                "default-issuer-kind": "ClusterIssuer",
              },
              env_+: {
                POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
              },
              ports_+: {
                prometheus: {containerPort: 9402},
              },
              resources: {
                requests: {cpu: "10m", memory: "32Mi"},
              },
            },
          },
        },
      },
    },
  },

  webhook: {
    local p = $.p + "cm-webhook",

    sa: kube.ServiceAccount(p) + $.metadata,

    requesterRole: kube.ClusterRole(p+"-requester") {
      rules: [{
        apiGroups: ["admission.certmanager.k8s.io"],
        resources: ["certificates", "issuers", "clusterissuers"],
        verbs: ["create"],
      }],
    },

    clusterRoleBinding: kube.ClusterRoleBinding(p+"-auth-delegator") {
      roleRef: {
        apiGroup: "rbac.authorization.k8s.io",
        kind: "ClusterRole",
        name: "system:auth-delegator",
      },
      subjects_+: [$.webhook.sa],
    },

    roleBinding: kube.RoleBinding(p+"-auth-reader") + $.metadata {
      roleRef: {
        apiGroup: "rbac.authorization.k8s.io",
        kind: "Role",
        name: "extension-apiserver-authentication-reader",
      },
      subjects_+: [$.webhook.sa],
    },

    svc: kube.Service(p) + $.metadata {
      port: 443,
      target_pod: $.webhook.deploy.spec.template,
    },

    deploy: kube.Deployment(p) + $.metadata {
      spec+: {
        template+: {
          spec+: {
            serviceAccountName: $.webhook.sa.metadata.name,
            volumes_+: {
              certs: kube.SecretVolume(p + "-tls"),
            },
            containers_+: {
              webhook: kube.Container("webhook") {
                image: CERT_MANAGER_WEBHOOK_IMAGE,
                args_+: {
                  v: "12",
                  "tls-cert-file": "/certs/tls.crt",
                  "tls-private-key-file": "/certs/tls.key",
                  "disable-admission-plugins": "NamespaceLifecycle,MutatingAdmissionWebhook,ValidatingAdmissionWebhook,Initializers",
                },
                env_+: {
                  POD_NAMESPACE: kube.FieldRef("metadata.namespace"),
                },
                resources+: {
                  requests: {cpu: "10m", memory: "32Mi"},
                },
                volumeMounts_+: {
                  certs: {mountPath: "/certs", readOnly: true},
                },
              },
            },
          },
        },
      },
    },

    apiservice: APIService("admission.certmanager.k8s.io", "v1beta1") {
      service_: $.webhook.svc,
      // NB: spec.caBundle is set by caSync job
    },

    selfsign: $.Issuer(p+"-selfsign") + $.namespace {
      metadata+: {
        annotations+: {
          "certmanager.k8s.io/disable-validation": "true",
        },
      },
      spec+: {
        selfsigned: {},
      },
    },

    caCert: $.Certificate(p+"-ca") + $.metadata {
      local this = self,
      metadata+: {
        annotations+: {
          "certmanager.k8s.io/disable-validation": "true",
        },
      },
      spec+: {
        secretName: this.metadata.name,
        issuerRef: {name: $.webhook.selfsign.metadata.name},
        commonName: "ca.webhook.cert-manager",
        isCA: true,
      },
    },

    caIssuer: $.Issuer(p+"-ca") + $.metadata {
      metadata+: {
        annotations+: {
          "certmanager.k8s.io/disable-validation": "true",
        },
      },
      spec+: {
        ca: {secretName: $.webhook.caCert.spec.secretName},
      },
    },

    cert: $.Certificate(p+"-tls") + $.metadata {
      local this = self,
      spec+: {
        secretName: this.metadata.name,
        issuerRef: {name: $.webhook.caIssuer.metadata.name},
        local svc = $.webhook.svc,
        dnsNames: [
          svc.metadata.name,
          "%s.%s" % [svc.metadata.name, svc.metadata.namespace],
          svc.host,
        ],
      },
    },

    validatingWebhook: ValidatingWebhookConfiguration(p) {
      webhooks: [
        {
          name: resource + ".admission.certmanager.k8s.io",
          namespaceSelector: {
            // NB! the actual namespace object of webhook certificate
            // (and friends) must be excluded here to allow webhook to
            // bootstrap.
            matchExpressions: [
              {
                key: "certmanager.k8s.io/disable-validation",
                operator: "NotIn",
                values: ["true"],
              },
              {
                key: "name",
                operator: "NotIn",
                values: [$.webhook.caCert.metadata.namespace],
              },
            ],
          },
          rules: [{
            apiGroups: ["certmanager.k8s.io"],
            apiVersions: ["v1alpha1"],
            operations: ["CREATE", "UPDATE"],
            resources: [resource],
          }],
          failurePolicy: "Fail",
          clientConfig: {
            service: {
              name: "kubernetes",
              namespace: "default",
              path: "/apis/admission.certmanager.k8s.io/v1beta1/" + resource,
            },
          },
        }
        for resource in ["certificates", "issuers", "clusterissuers"]
      ],
    },

    caSync: {
      local p = $.p + "cm-webhook-ca-sync",

      config: kube.ConfigMap(p) + $.metadata {
        data+: {
          config_:: {
            apiServices: [{
              name: $.webhook.apiservice.metadata.name,
              secret: {
                local ca = $.webhook.ca,
                name: ca.spec.secretName,
                namespace: ca.metadata.namespace,
                key: "tls.crt",
              },
            }],
            validatingWebhookConfigurations: [{
              name: $.webhook.validatingWebhook.metadata.name,
              file: {
                path: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
              },
            }],
          },
          config: kubecfg.manifestJson(self.config_),
        },
      },

      sa: kube.ServiceAccount(p) + $.metadata,

      clusterRole: kube.ClusterRole(p) + $.metadata {
        rules: [
          {
            apiGroups: [""],
            resources: ["secrets"],
            verbs: ["get"],
            resourceNames: ["webhook-ca"],
          },
          {
            apiGroups: ["admissionregistration.k8s.io"],
            resources: ["validatingwebhookconfigurations", "mutatingwebhookconfigurations"],
            verbs: ["get", "update"],
            resourceNames: ["webhook"],
          },
          {
            apiGroups: ["apiregistration.k8s.io"],
            resources: ["apiservices"],
            verbs: ["get", "update"],
            resourceNames: ["v1beta1.admission.certmanager.k8s.io"],
          },
        ],
      },

      binding: kube.ClusterRoleBinding(p) + $.metadata {
        roleRef_+: $.webhook.caSync.clusterRole,
        subjects_+: [$.webhook.caSync.sa],
      },

      // Update the APIService caBundle once at manifest update-time
      job: kube.Job(p) + $.metadata {
        spec+: {
          template+: {
            spec+: {
              serviceAccountName: $.webhook.caSync.sa.metadata.name,
              volumes_+: {
                config: kube.ConfigMap($.webhook.caSync.config),
              },
              containers_+: {
                helper: kube.Container("ca-helper") {
                  image: "quay.io/munnerz/apiextensions-ca-helper:v0.1.0",
                  args_+: {
                    config: "/config/config",
                  },
                  volumeMounts_+: {
                    config: {mountPath: "/config", readOnly: true},
                  },
                  resources+: {
                    requests: {cpu: "10m", memory: "32Mi"},
                    limits: {cpu: "100m", memory: "128Mi"},
                  },
                },
              },
            },
          },
        },
      },

      // .. and re-run again periodically.
      cronjob: kube.CronJob(p) + $.metadata {
        spec+: {
          schedule: "* * */24 * *",  // every 24h
          jobTemplate+: {
            spec+: $.webhook.caSync.job.spec,
          },
        },
      },
    },
  },

  letsencryptStaging: $.ClusterIssuer($.p+"letsencrypt-staging") {
    local this = self,
    spec+: {
      acme+: {
        server: "https://acme-staging-v02.api.letsencrypt.org/directory",
        email: $.letsencrypt_contact_email,
        privateKeySecretRef: {name: this.metadata.name},
        http01: {},
      },
    },
  },

  letsencryptProd: $.letsencryptStaging {
    metadata+: {name: $.p+"letsencrypt-prod"},
    spec+: {
      acme+: {
        server: "https://acme-v02.api.letsencrypt.org/directory",
      },
    },
  },
}
