FROM docker:29-cli AS docker-tools

FROM eclipse-temurin:21-jdk-jammy

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash curl jq shellcheck tar git openssh-client iproute2 ca-certificates \
    && useradd --uid 10001 --user-group --create-home --shell /bin/bash demo \
    && ln -s /opt/java/openjdk/bin/java /usr/local/bin/java \
    && ln -s /opt/java/openjdk/bin/javac /usr/local/bin/javac \
    && rm -rf /var/lib/apt/lists/*

COPY --from=docker-tools /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-tools /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/

# Les binaires officiels sont controles avec leurs sommes SHA-256.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) tool_arch=amd64 ;; \
      arm64) tool_arch=arm64 ;; \
      *) echo "Architecture non prise en charge" >&2; exit 1 ;; \
    esac; \
    cd /usr/local/bin; \
    curl -fsSLo minikube "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${tool_arch}"; \
    curl -fsSLo minikube.sha256 "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${tool_arch}.sha256"; \
    printf '%s  minikube\n' "$(cat minikube.sha256)" | sha256sum -c -; \
    kube_version=$(curl -fsSL https://dl.k8s.io/release/stable.txt); \
    curl -fsSLo kubectl "https://dl.k8s.io/release/${kube_version}/bin/linux/${tool_arch}/kubectl"; \
    curl -fsSLo kubectl.sha256 "https://dl.k8s.io/release/${kube_version}/bin/linux/${tool_arch}/kubectl.sha256"; \
    printf '%s  kubectl\n' "$(cat kubectl.sha256)" | sha256sum -c -; \
    chmod +x minikube kubectl; \
    java -version; javac -version; docker compose version; \
    minikube version; kubectl version --client

COPY entrypoint.sh /usr/local/bin/validation-entrypoint.sh
# Le build peut partir d'une copie de travail Windows avant git add.
RUN sed -i 's/\r$//' /usr/local/bin/validation-entrypoint.sh \
    && chmod +x /usr/local/bin/validation-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/validation-entrypoint.sh"]
