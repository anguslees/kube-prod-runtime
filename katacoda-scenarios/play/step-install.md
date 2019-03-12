BKPR assumes you have a new empty cluster from one of the supported
platforms.

#### Fetch the `kubeprod` installer:

`
wget https://github.com/bitnami/kube-prod-runtime/releases/download/v1.1.2/bkpr-v1.1.2-linux-amd64.tar.gz
tar zxf bkpr-v1.1.2-linux-amd64.tar.gz
mv bkpr-v1.1.2/kubeprod /usr/local/bin/
`{{execute}}

#### Run the installer:

`
kubeprod install katacoda --dns-zone [[HOST_SUBDOMAIN]]-[[KATACODA_HOST]].environments.katacoda.com
`{{execute}}
