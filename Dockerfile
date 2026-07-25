ARG BASE_IMAGE=docker.io/library/debian:trixie-slim
ARG UI_ASSETS_IMAGE=ghcr.io/troibe/argocd/ui-assets:latest
####################################################################################################
# Builder image
# Initial stage which pulls prepares build dependencies and CLI tooling we need for our final image
# Also used as the image in CI jobs so needs all dependencies
####################################################################################################
FROM docker.io/library/golang:1.26.4@sha256:68cb6d68bed024785b69195b89af7ac7a444f27791435f98647edff595aa0479 AS builder

WORKDIR /tmp

RUN echo 'deb http://archive.debian.org/debian buster-backports main' >> /etc/apt/sources.list

RUN apt-get update && apt-get install --no-install-recommends -y \
    openssh-server \
    nginx \
    unzip \
    fcgiwrap \
    git \
    make \
    wget \
    gcc \
    sudo \
    zip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY hack/install.sh hack/tool-versions.sh ./
COPY hack/installers installers

RUN ./install.sh helm && \
    INSTALL_PATH=/usr/local/bin ./install.sh kustomize && \
    ./install.sh git-lfs

####################################################################################################
# Argo CD Base - used as the base for both the release and dev argocd images
####################################################################################################
FROM $BASE_IMAGE AS argocd-base

LABEL org.opencontainers.image.source="https://github.com/argoproj/argo-cd"

USER root

ENV ARGOCD_USER_ID=999 \
    DEBIAN_FRONTEND=noninteractive

RUN groupadd -g $ARGOCD_USER_ID argocd && \
    useradd -r -u $ARGOCD_USER_ID -g argocd argocd && \
    mkdir -p /home/argocd && \
    chown argocd:0 /home/argocd && \
    chmod g=u /home/argocd && \
    apt-get update && \
    apt-get dist-upgrade -y && \
    apt-get install --no-install-recommends -y \
    git tini ca-certificates gpg gpg-agent tzdata connect-proxy openssh-client && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/*

COPY hack/gpg-wrapper.sh \
    hack/git-verify-wrapper.sh \
    entrypoint.sh \
    /usr/local/bin/
COPY --from=builder /usr/local/bin/helm /usr/local/bin/helm
COPY --from=builder /usr/local/bin/kustomize /usr/local/bin/kustomize
COPY --from=builder /usr/local/bin/git-lfs /usr/local/bin/git-lfs

# Initialize git-lfs system configuration (/etc/gitconfig) so LFS filters are active
RUN git lfs install --system

# keep uid_entrypoint.sh for backward compatibility
RUN ln -s /usr/local/bin/entrypoint.sh /usr/local/bin/uid_entrypoint.sh

# support for mounting configuration from a configmap
WORKDIR /app/config/ssh
RUN touch ssh_known_hosts && \
    ln -s /app/config/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts

WORKDIR /app/config
RUN mkdir -p tls && \
    mkdir -p gpg/source && \
    mkdir -p gpg/keys && \
    chown argocd gpg/keys && \
    chmod 0700 gpg/keys

ENV USER=argocd

# Disable gRPC service config lookups via DNS TXT records to prevent excessive
# DNS queries for _grpc_config.<hostname> which can cause timeouts in dual-stack
# environments. This can be overridden via argocd-cmd-params-cm ConfigMap.
# See https://github.com/argoproj/argo-cd/issues/24991
ENV GRPC_ENABLE_TXT_SERVICE_CONFIG=false

USER $ARGOCD_USER_ID
WORKDIR /home/argocd

####################################################################################################
# Argo CD UI assets stage
####################################################################################################
FROM ${UI_ASSETS_IMAGE} AS argocd-ui-assets

####################################################################################################
# Argo CD Build stage which performs the actual build of Argo CD binaries
####################################################################################################
FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.26.4@sha256:68cb6d68bed024785b69195b89af7ac7a444f27791435f98647edff595aa0479 AS argocd-build

WORKDIR /go/src/github.com/argoproj/argo-cd

# Keep Go's module and build caches in stable locations so Kaniko can reuse
# the cacheable dependency layer when only source files change.
ENV GOCACHE=/root/.cache/go-build \
    GOMODCACHE=/go/pkg/mod

COPY go.* ./
RUN mkdir -p gitops-engine
COPY gitops-engine/go.* ./gitops-engine/
RUN go mod download

# Perform the build
COPY . .
COPY --from=argocd-ui-assets /dist/app /go/src/github.com/argoproj/argo-cd/ui/dist/app
ARG TARGETOS \
    TARGETARCH
# These build args are optional; if not specified the defaults will be taken from the Makefile
ARG GIT_TAG \
    BUILD_DATE \
    GIT_TREE_STATE \
    GIT_COMMIT
RUN echo '--- git status (tracked and untracked) ---' && \
    git status --porcelain=v1 --untracked-files=all && \
    echo '--- unstaged diff ---' && \
    git diff --name-status && \
    echo '--- staged diff ---' && \
    git diff --cached --name-status && \
    echo '--- ignored status ---' && \
    git status --porcelain=v1 --ignored && \
    GIT_COMMIT=$GIT_COMMIT \
    GIT_TREE_STATE=$GIT_TREE_STATE \
    GIT_TAG=$GIT_TAG \
    BUILD_DATE=$BUILD_DATE \
    GOOS=$TARGETOS \
    GOARCH=$TARGETARCH \
    make argocd-all

####################################################################################################
# Final image
####################################################################################################
FROM argocd-base
ENTRYPOINT ["/usr/bin/tini", "--"]
COPY --from=argocd-build /go/src/github.com/argoproj/argo-cd/dist/argocd* /usr/local/bin/

USER root
RUN ln -s /usr/local/bin/argocd /usr/local/bin/argocd-server && \
    ln -s /usr/local/bin/argocd /usr/local/bin/argocd-repo-server && \
    ln -s /usr/local/bin/argocd /usr/local/bin/argocd-cmp-server && \
    ln -s /usr/local/bin/argocd /usr/local/bin/argocd-application-controller && \
    ln -s /usr/local/bin/argocd /usr/local/bin/argocd-dex && \
    ln -s /usr/local/bin/argocd /usr/local/bin/argocd-notifications && \
    ln -s /usr/local/bin/argocd /usr/local/bin/argocd-applicationset-controller && \
    ln -s /usr/local/bin/argocd /usr/local/bin/argocd-k8s-auth && \
    ln -s /usr/local/bin/argocd /usr/local/bin/argocd-commit-server

USER $ARGOCD_USER_ID
