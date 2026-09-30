# Receptor sidecar for the standalone AWX lab.
#
# Outside Kubernetes, AWX 23.x always runs a job through ansible-runner
# process isolation, i.e. `podman run <execution environment image> ...` on
# the execution node. The stock awx-ee image ships receptor + ansible-runner
# but not podman, so add it here. The container runs privileged (see
# docker-compose.yml) so rootful podman can start the nested EE containers.
ARG AWX_EE_IMAGE=quay.io/ansible/awx-ee:23.8.1
FROM ${AWX_EE_IMAGE}

USER 0
RUN dnf install -y podman fuse-overlayfs && dnf clean all

COPY containers.conf /etc/containers/containers.conf
