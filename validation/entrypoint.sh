#!/usr/bin/env bash
# Execute le script rendu dans un Linux temporaire, avec son propre Docker.
set -Eeuo pipefail

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    printf '%s\n' "$status" > /reports/exit-code.txt
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p /reports /home/demo/exam
chown demo:demo /reports
printf 'EN COURS\n' > /reports/exit-code.txt
printf 'Verification du Docker interne de validation Linux...\n'
# Les deux conteneurs partagent le reseau pour joindre les ports locaux
# publies par Compose et Minikube dans le moteur Docker interne.
deadline=$((SECONDS + 90))
until docker info >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
        docker info >&2
        exit 1
    fi
    sleep 1
done

# Copier les fichiers non commites aussi. Ne pas copier les rapports,
# artefacts Windows, caches Maven ni les metadonnees Git.
tar -C /source --exclude='*/target' --exclude='*/.idea' --exclude='*/.vscode' \
    -cf - demo.sh scripts movie-service ticket-service k8s broken \
    docker-compose.yaml reponses.md README.md DEMONSTRATION.md \
    | tar -C /home/demo/exam -xf -

# Simuler le checkout LF impose par .gitattributes sans toucher aux originaux.
for script in /home/demo/exam/demo.sh /home/demo/exam/scripts/*.sh \
    /home/demo/exam/movie-service/mvnw /home/demo/exam/ticket-service/mvnw; do
    sed -i 's/\r$//' "$script"
done
ln -sfn /reports /home/demo/exam/reports
# Ce chown vise la copie interne ; /source est monte en lecture seule.
chown -R demo:demo /home/demo/exam
cd /home/demo/exam
sha256sum demo.sh scripts/*.sh > /reports/scripts-sha256.txt

printf 'Execution Linux : tests internes, prerequis, parties 1 a 7 et bonus.\n'
# Le pilote Minikube Docker est lance par un utilisateur non root.
su - demo -c 'export DOCKER_HOST=tcp://127.0.0.1:2375 NO_COLOR=1
    cd /home/demo/exam &&
    shellcheck demo.sh scripts/demo-lib.sh scripts/test-demo.sh &&
    bash scripts/test-demo.sh &&
    bash demo.sh --check &&
    bash demo.sh --profile cinek8s-demo-linux'
