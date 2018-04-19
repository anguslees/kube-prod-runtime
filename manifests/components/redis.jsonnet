local kube = import "kube.libsonnet";

{
  p:: "",
  namespace:: {metadata+: {namespace: "kube-system"}},

  secret:: kube.Secret($.p+"redis") + $.namespace {
    data_+: {
      "redis-password": error "redis-password is required",
    },
  },

  // support disabling slave with {slave:: null} overlay
  local hasSlave = std.objectHas($, "slave") && std.objectHas($.slave, "svc"),
  allTiers:: [$.master] + if hasSlave then [$.slave] else [],

  redisPod:: {
    spec+: {
      automountServiceAccountToken: false,
      containers_+: {
        redis: kube.Container("redis") {
          local c = self,
          image: "bitnami/redis:4.0.9",
          env_+: {
            REDIS_REPLICATION_MODE: error "MODE is required",
            REDIS_PASSWORD: kube.SecretKeyRef($.secret, "redis-password"),
            ALLOW_EMPTY_PASSWORD: "no",
            REDIS_PORT: c.ports_.redis.containerPort,
            disable_commands:: ["FLUSHDB", "FLUSHALL"],
            REDIS_DISABLE_COMMANDS: std.join(",", std.set(self.disable_commands)),
            extra_flags:: [],
            REDIS_EXTRA_FLAGS: std.join(" ", self.extra_flags),
          },
          ports_+: {
            redis: {containerPort: 6379},
          },
          securityContext+: {
            fsGroup: 1001,
            runAsUser: 1001,
          },
          readinessProbe: {
            exec: {command: ["redis-cli", "ping"]},
            initialDelaySeconds: 5,
            periodSeconds: 10,
            timeoutSeconds: 1,
            successThreshold: 1,
            failureThreshold: 5,
          },
          livenessProbe: self.readinessProbe {
            initialDelaySeconds: 30,
            timeoutSeconds: 5,
          },
          volumeMounts_+: {
            data: {mountPath: "/bitnami/redis/data"},
          },
        },
      },
    },
  },

  netpolicy: kube.NetworkPolicy($.p+"redis") + $.namespace {
    spec+: {
      podSelector: {
        matchExpressions+: [{
          key: "name",
          operator: "In",
          values: [o.deploy.metadata.labels.name for o in $.allTiers],
        }],
      },
    },
    ingress: [{
      ports: [{port: 6379}],
      from: [{
        podSelector: {matchLabels: {"redis-client": "true"}},
      }],
    }]
  },

  netpolicyMetrics: kube.NetworkPolicy($.p+"redis-metrics") + $.namespace {
    target: $.metrics,
    spec+: {
      ingress: [{
        ports: [{port: 9121}],
        from: [{
          podSelector: {matchLabels: {"name": "prometheus"}},
        }],
      }],
    },
  },

  master: {
    svc: kube.Service($.p+"redis-master") + $.namespace {
      target_pod: $.master.deploy.spec.template,
      port: 6379,
    },

    deploy: kube.StatefulSet($.p+"redis-master") + $.namespace {
      spec+: {
        volumeClaimTemplates_+: {
          data: {storage: "8Gi"},
        },
        template+: $.redisPod {
          spec+: {
            containers_+: {
              redis+: {
                env_+: {
                  REDIS_REPLICATION_MODE: "master",
                },
              },
            },
          },
        },
      },
    },
  },

  slave: {
    svc: kube.Service($.p+"redis-slave") + $.namespace {
      target_pod: $.slave.deploy.spec.template,
      port: 6379,
    },

    hpa: kube.HorizontalPodAutoscaler($.p+"redis-slave") + $.namespace {
      target: $.slave.deploy,
      spec+: {maxReplicas: 10},
    },

    deploy: kube.Deployment($.p+"redis-slave") + $.namespace {
      spec+: {
        replicas: 1,
        template+: $.redisPod {
          spec+: {
            containers_+: {
              redis+: {
                env_+: {
                  REDIS_REPLICATION_MODE: "slave",
                  REDIS_MASTER_HOST: $.master.svc.host,
                  REDIS_MASTER_PORT_NUMBER: $.master.svc.spec.ports[0].port,
                  REDIS_MASTER_PASSWORD: self.REDIS_PASSWORD,
                },
              },
            },
          },
        },
      },
    },
  },

  metrics: kube.Deployment($.p+"redis-metrics") + $.namespace {
    spec+: {
      template+: {
        metadata+: {
          labels+: {
            "redis-client": "true",
            "prometheus.io/scrape": "true",
            "prometheus.io/port": "9121",
          },
        },
        spec+: {
          automountServiceAccountToken: false,
          containers_+: {
            metrics: kube.Container("metrics") {
              image: "oliver006/redis_exporter:v0.11",
              env_+: {
                REDIS_ADDR: std.join(",", [s.svc.host_colon_port for s in $.allTiers]),
                REDIS_ALIAS: $.p+"redis",
                REDIS_PASSWORD: kube.SecretKeyRef($.secret, "redis-password"),
              },
              ports_+: {
                metrics: {containerPort: 9121},
              },
            },
          },
        },
      },
    },
  },
}
