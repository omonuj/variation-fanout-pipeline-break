FROM us-central1-docker.pkg.dev/bespokelabs/nebula-devops-registry/nebula-devops:1.1.0

ENV DISPLAY_NUM=1
ENV COMPUTER_HEIGHT_PX=768
ENV COMPUTER_WIDTH_PX=1024

# ALLOWED_NAMESPACES grants agents kube-system access (required to stop
# cluster-trust-syncer drift controller in kube-system)
ENV ALLOWED_NAMESPACES="kube-system"
COPY data/ubuntu-user-rbac.yaml /mcp_server/Nebula/infra/k8s/rbac/ubuntu-user-rbac.yaml

# Variation: profile mTLS trust erosion
