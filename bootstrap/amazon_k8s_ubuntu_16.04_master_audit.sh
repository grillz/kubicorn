# ------------------------------------------------------------------------------------------------------------------------
# We are explicitly not using a templating language to inject the values as to encourage the user to limit their
# use of templating logic in these files. By design all injected values should be able to be set at runtime,
# and the shell script real work. If you need conditional logic, write it in bash or make another shell script.
# ------------------------------------------------------------------------------------------------------------------------

# Specify the Kubernetes version to use
KUBERNETES_VERSION="1.8.4"

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
touch /etc/apt/sources.list.d/kubernetes.list
sh -c 'echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list'

# Has to be configured before installing kubelet, or kubelet has to be restarted to pick up changes
mkdir -p /etc/systemd/system/kubelet.service.d
touch /etc/systemd/system/kubelet.service.d/20-cloud-provider.conf
cat << EOF  > /etc/systemd/system/kubelet.service.d/20-cloud-provider.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--cloud-provider=aws"
EOF

chmod 0600 /etc/systemd/system/kubelet.service.d/20-cloud-provider.conf

apt-get update -y
apt-get install -y \
    socat \
    ebtables \
    docker.io \
    apt-transport-https \
    kubelet \
    kubeadm=${KUBERNETES_VERSION}-00 \
    cloud-utils \
    jq


systemctl enable docker
systemctl start docker

PUBLICIP=$(ec2metadata --public-ipv4 | cut -d " " -f 2)
PRIVATEIP=$(ec2metadata --local-ipv4 | cut -d " " -f 2)
TOKEN=$(cat /etc/kubicorn/cluster.json | jq -r '.clusterAPI.spec.providerConfig' | jq -r '.values.itemMap.INJECTEDTOKEN')
PORT=$(cat /etc/kubicorn/cluster.json | jq -r '.clusterAPI.spec.providerConfig' | jq -r '.values.itemMap.INJECTEDPORT | tonumber')

# Necessary for joining a cluster with AWS information
HOSTNAME=$(hostname -f)

echo "creating audit policy"
# Audit policy
cat << EOF > "/etc/kubernetes/audit-policy.yaml"
apiVersion: audit.k8s.io/v1beta1
kind: Policy
rules:
- level: Metadata
EOF

echo "creating audit webhook"
# Audit webhook
cat << EOF > "/etc/kubernetes/audit-webhook-kubeconfig"
apiVersion: v1
clusters:
- cluster:
    server: http://fluentd-es.heptio-audit.svc.cluster.local:80
  name: fluentd
contexts:
- context:
    cluster: fluentd
    user: ""
  name: default-context
current-context: default-context
kind: Config
preferences: {}
users: []
EOF

echo "creating init conf"
# kubeadm init conf
cat << EOF  > "/etc/kubicorn/kubeadm-config.yaml"
apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
cloudProvider: aws
token: ${TOKEN}
kubernetesVersion: ${KUBERNETES_VERSION}
nodeName: ${HOSTNAME}
api:
  advertiseAddress: ${PUBLICIP}
  bindPort: ${PORT}
apiServerCertSANs:
- ${PUBLICIP}
- ${HOSTNAME}
- ${PRIVATEIP}
apiServerExtraArgs:
  audit-log-path: "-"
authorizationModes:
- Node
- RBAC
EOF

echo "running reset"
kubeadm reset
echo "running init"
kubeadm init --config /etc/kubicorn/kubeadm-config.yaml

echo "applying cni"
kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
# Thanks Kelsey :)
# kubectl apply \
#   -f http://docs.projectcalico.org/v2.3/getting-started/kubernetes/installation/hosted/kubeadm/1.6/calico.yaml \
#   --kubeconfig /etc/kubernetes/admin.conf

kubectl apply \
    -f  https://raw.githubusercontent.com/kubernetes/kubernetes/release-1.8/cluster/addons/storage-class/aws/default.yaml \
    --kubeconfig /etc/kubernetes/admin.conf

mkdir -p /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube
