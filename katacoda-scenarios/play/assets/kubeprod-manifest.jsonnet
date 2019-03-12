// Cluster-specific configuration
//local bkpr = import "https://github.com/bitnami/kube-prod-runtime/raw/master/manifests/platforms/katacoda.jsonnet";
local bkpr = import "/root/platforms-katacoda.jsonnet";

bkpr {
        config:: import "kubeprod-autogen.json",
        // Place your overrides here
}
