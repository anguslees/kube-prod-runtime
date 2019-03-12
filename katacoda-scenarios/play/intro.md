Bitnami Kubernetes Production Runtime working example.  You can play
with installing and using BKPR in a small sandboxed test cluster.

**Note** that the BKPR installation has been simplified for this
environment. The principal changes are:

- Reduced number of replicas.  BKPR "defaults to production" and
  usually has at least 2 AZ-diverse replicas for each of the jobs in
  the serving path.  This sandbox has only a single replica for these
  jobs.
- No managed DNS.  BKPR usually uses your cloud provider's managed DNS
  solution to automatically update DNS records.
- No OAuth2 authentication.  BKPR usually uses your cloud provider's
  OAuth2 integration to provide protect the provided consoles
  (prometheus, kibana, etc).
