local kube = import "kube.libsonnet";
local utils = import "utils.libsonnet";

// See https://docs.microsoft.com/en-us/azure/aks/integrate-azure
// https://github.com/Azure/open-service-broker-azure/blob/master/docs/quickstart-aks.md

{
  p:: "",
  namespace:: {metadata+: {namespace: "kube-system"}},

  redis: error "redis is required",

  authSecret:: kube.Secret($.p+"osba-auth") + $.namespace {
    data_+: {
      username: error "username is required",
      password: error "password is required",
    },
  },

  secret:: kube.Secret($.p+"osba") + $.namespace {
    data_+: {
      "default-location": error "default-location is required",
      "encryption-key": error "encryption-key is required",
    },
  },

  azureAuth:: kube.Secret($.p+"osba-azure") + $.namespace {
    data_+: {
      subscriptionId: error "subscriptionId is required",
      tenantId: error "tenantId is required",
      clientId: error "clientId is required",
      clientSecret: error "clientSecret is required",
    },
  },

  svc: kube.Service($.p+"osba") + $.namespace {
    target_pod: $.deploy.spec.template,
    port: 8080,
  },

  broker: utils.ClusterServiceBroker($.p+"osba") {
    spec+: {
      url: $.svc.http_url,
      authInfo: {
        basic: {
          secretRef: {
            local s = $.authSecret,
            name: s.metadata.name,
            namespace: s.metadata.namespace,
          },
        },
      },
    },
  },

  deploy: kube.Deployment($.p+"osba") + $.namespace {
    spec+: {
      template+: {
        spec+: {
          containers_+: {
            osba: kube.Container("osba") {
              image: "microsoft/azure-service-broker:v0.10.0",
              env_+: {
                ENVIRONMENT: "AzurePublicCloud",  // TODO: almost but not quite `az cloud show`
                AZURE_SUBSCRIPTION_ID: kube.SecretKeyRef($.azureAuth, "subscriptionId"),
                AZURE_TENANT_ID: kube.SecretKeyRef($.azureAuth, "tenantId"),
                AZURE_CLIENT_ID: kube.SecretKeyRef($.azureAuth, "clientId"),
                AZURE_CLIENT_SECRET: kube.SecretKeyRef($.azureAuth, "clientSecret"),
                AZURE_DEFAULT_LOCATION: kube.SecretKeyRef($.secret, "default-location"),
                REDIS_HOST: $.redis.master.svc.host,
                REDIS_PORT: $.redis.master.svc.spec.ports[0].port,
                REDIS_ENABLE_TLS: false,
                REDIS_PASSWORD: kube.SecretKeyRef($.redis.secret, "redis-password"),
                AES256_KEY: kube.SecretKeyRef($.secret, "encryption-key"),
                BASIC_AUTH_USERNAME: kube.SecretKeyRef($.authSecret, "username"),
                BASIC_AUTH_PASSWORD: kube.SecretKeyRef($.authSecret, "password"),
                MIN_STABILITY: "STABLE", // or PREVIEW, EXPERIMENTAL
              },
              ports_+: {
                default: {containerPort: 8080},
              },
              readinessProbe: {
                tcpSocket: {port: 8080},
                failureThreshold: 1,
                initialDelaySeconds: 10,
                periodSeconds: 10,
                successThreshold: 1,
                timeoutSeconds: 2,
              },
              livenessProbe: self.readinessProbe {
                failureThreshold: 3,
                initialDelaySeconds: 30,
              },
            },
          },
        },
      },
    },
  },
}
