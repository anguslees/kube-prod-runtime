#### Customize base BKPR install

todo

#### Install `kubecfg`:

`
wget https://github.com/ksonnet/kubecfg/releases/download/v0.9.1/kubecfg-linux-amd64
install -m755 kubecfg-linux-amd64 /usr/local/bin/kubecfg
`{{execute}}

`kubecfg update --ignore-unknown --gc-tag=kubeprod ~/kubeprod-manifest.jsonnet`{{execute}}
