#!/usr/bin/env bash
# Script BY Younes
# Demonstration de l'examen : bash demo.sh (Linux/macOS).
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROFILE=cinek8s-demo
BASE_PORT=18080
CHECK_ONLY=0

usage() {
    cat <<'HELP'
Script BY Younes
CineK8s — demonstration de l'examen, parties 1 a 7 et bonus

  bash demo.sh                      Lancer toutes les etapes
  bash demo.sh --check              Verifier uniquement les prerequis
  bash demo.sh --profile cinek8s-demo-prof --port-base 19080
  bash demo.sh --help

Prerequis : Bash 3.2+, JDK Java 21+, Docker avec Compose v2, Minikube,
kubectl, curl et jq. Docker doit etre demarre. Acces Internet au premier build.
Le cluster dedie est conserve. Les processus locaux et Compose sont arretes.
Les rapports sont enregistres dans reports/. Aucun fichier hosts n'est modifie.
HELP
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --check) CHECK_ONLY=1; shift ;;
        --profile|--port-base)
            if [ "$#" -lt 2 ]; then printf 'Valeur manquante : %s\n' "$1" >&2; exit 2; fi
            if [ "$1" = --profile ]; then PROFILE=$2; else BASE_PORT=$2; fi
            shift 2 ;;
        *) printf 'Option inconnue : %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

# Un profil de demonstration explicite empeche de viser un cluster habituel.
if ! [[ "$PROFILE" =~ ^cinek8s-demo(-[a-z0-9]+)*$ ]]; then
    printf 'Le profil doit etre cinek8s-demo ou cinek8s-demo-<suffixe>.\n' >&2; exit 2
fi
if ! [[ "$BASE_PORT" =~ ^[0-9]{4,5}$ ]] || [ "$BASE_PORT" -lt 1024 ] || [ "$BASE_PORT" -gt 65529 ]; then
    printf 'Le port de base doit etre compris entre 1024 et 65529.\n' >&2; exit 2
fi
# Forcer la base 10, meme si un nombre a ete ecrit avec un zero initial.
BASE_PORT=$((10#$BASE_PORT))
MOVIE_PORT=$((BASE_PORT + 5)); TICKET_PORT=$((BASE_PORT + 6))
MOVIE_URL="http://127.0.0.1:$MOVIE_PORT"
TICKET_URL="http://127.0.0.1:$TICKET_PORT"
INGRESS_URL="http://127.0.0.1:$BASE_PORT"
RUN_DIR="$ROOT_DIR/reports/$(date '+%Y%m%d-%H%M%S')-$$"
mkdir -p "$RUN_DIR"
: > "$RUN_DIR/checks.tsv"; : > "$RUN_DIR/commands.log"; : > "$RUN_DIR/http.log"
START_DATE=$(date '+%Y-%m-%dT%H:%M:%S%z'); START_SECONDS=$SECONDS
STAGE=Prerequis; PASSED=0; FAILED=0
MOVIE_PID=''; TICKET_PID=''; TICKET_PF_PID=''; INGRESS_PF_PID=''; TRAFFIC_PID=''
FORWARD_PID=''; COMPOSE_STARTED=0; CLUSTER_STARTED=0; MOVIE_DOWN=0; DEBUG_CREATED=0
BLUE=''; GREEN=''; RED=''; RESET=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BLUE=$'\033[1;34m'; GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; RESET=$'\033[0m'
fi
# shellcheck source=scripts/demo-lib.sh
source "$ROOT_DIR/scripts/demo-lib.sh"
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cd "$ROOT_DIR"

printf '\n%s========================================\n         Script BY Younes\n========================================%s\n' "$RED" "$RESET"
printf 'Script BY Younes\n' >> "$RUN_DIR/console.log"

section 'Prerequis — avant toute modification'
for tool in java javac docker minikube kubectl curl jq; do check "Commande disponible : $tool" command -v "$tool"; done
check 'Fichier de reponses present' test -s reponses.md
for port in "$BASE_PORT" "$MOVIE_PORT" "$TICKET_PORT"; do
    if (: > "/dev/tcp/127.0.0.1/$port") 2>/dev/null; then fail "Port $port deja utilise" 'Choisir un autre --port-base.'; fi
    record OK "Port $port disponible"
done
capture "$RUN_DIR/java-version.txt" bash -c 'java -version 2>&1'
java_major=$(sed -nE 's/.*version "([0-9]+).*/\1/p' "$RUN_DIR/java-version.txt" | head -1)
check 'Java 21 ou plus recent' test "${java_major:-0}" -ge 21
run docker info --format 'Docker {{.ServerVersion}} — {{.NCPU}} CPU — {{.MemTotal}} octets'
run docker compose version
run minikube version
run kubectl version --client
if [ "$CHECK_ONLY" -eq 1 ]; then log 'Prerequis verifies. Aucun deploiement effectue.'; exit 0; fi

section 'Partie 1 — configuration et lecture du code'
check 'Readiness ticket dependante de movie' grep -Eq 'include:[[:space:]]*readinessState,[[:space:]]*movie' ticket-service/src/main/resources/application.yaml
check 'Arret gracieux de movie' grep -Eq 'shutdown:[[:space:]]*graceful' movie-service/src/main/resources/application.yaml
log 'Les explications Q1.1 a Q1.4 sont dans reponses.md. Les comportements HTTP seront verifies ci-dessous.'

section 'Partie 2 — compilation, tests Maven et lancement local'
for service in movie-service ticket-service; do
    log "Compilation et tests : $service"
    (cd "$ROOT_DIR/$service"; run bash ./mvnw -B clean verify -DskipTests=false -Dmaven.test.skip=false)
    record OK "Tests Maven : $service"
    mkdir -p "$RUN_DIR/tests-$service"
    cp "$ROOT_DIR/$service"/target/surefire-reports/*.xml "$RUN_DIR/tests-$service/"
    tests_run=$( { grep -h -o '<testcase' "$RUN_DIR/tests-$service/"*.xml || true; } | wc -l | tr -d ' ')
    check "Au moins un test Maven execute : $service ($tests_run)" test "$tests_run" -gt 0
done
SERVER_PORT="$MOVIE_PORT" MOVIE_ENVIRONMENT=local java -jar movie-service/target/movie-service-1.0.0.jar > "$RUN_DIR/movie-local.log" 2>&1 &
MOVIE_PID=$!
wait_http "$MOVIE_URL/actuator/health/liveness" 200 'Movie local demarre'
SERVER_PORT="$TICKET_PORT" MOVIE_URL="$MOVIE_URL" java -jar ticket-service/target/ticket-service-1.0.0.jar > "$RUN_DIR/ticket-local.log" 2>&1 &
TICKET_PID=$!
wait_http "$TICKET_URL/actuator/health/readiness" 200 'Ticket local pret'
expect_http 'Environnement local' 200 "$MOVIE_URL/api/movies/whoami"
expect_json 'MOVIE_ENVIRONMENT=local' '.environment == "local"'
expect_http 'Reservation de trois places' 201 "$TICKET_URL/api/tickets" '{"movieId":2,"seats":3}'
expect_json 'Total de la reservation : 36 euros' '.total == 36 and .movieId == 2 and .seats == 3'
expect_http 'Film inconnu' 422 "$TICKET_URL/api/tickets" '{"movieId":999,"seats":1}'
expect_http 'Places insuffisantes' 409 "$TICKET_URL/api/tickets" '{"movieId":2,"seats":4}'
expect_http 'Nombre de places invalide' 400 "$TICKET_URL/api/tickets" '{"movieId":1,"seats":0}'
stop_pid "$MOVIE_PID"; MOVIE_PID=''
wait_http "$TICKET_URL/actuator/health/readiness" 503 'Movie arrete : ticket non pret'
expect_json 'Readiness DOWN, liveness independante' '.status == "DOWN" and .components.movie.status == "DOWN"'
expect_http 'Liveness reste UP' 200 "$TICKET_URL/actuator/health/liveness"
expect_json 'Etat de liveness' '.status == "UP"'
expect_http 'Reservation sans movie' 503 "$TICKET_URL/api/tickets" '{"movieId":2,"seats":3}'
stop_pid "$TICKET_PID"; TICKET_PID=''

section 'Partie 3 — Docker et Compose'
# Compose config resout les chemins de build. On change uniquement les ports
# publies pour la demonstration, sans reecrire le fichier rendu.
capture "$RUN_DIR/compose-original.json" docker compose -f "$ROOT_DIR/docker-compose.yaml" config --format json
jq --arg movie "$MOVIE_PORT" --arg ticket "$TICKET_PORT" '
    .services.movie.ports = [{target:8080,published:$movie,host_ip:"127.0.0.1",protocol:"tcp"}] |
    .services.ticket.ports = [{target:8080,published:$ticket,host_ip:"127.0.0.1",protocol:"tcp"}]
' "$RUN_DIR/compose-original.json" > "$RUN_DIR/compose.json"
COMPOSE_STARTED=1
run compose up --build -d
capture "$RUN_DIR/docker-images.json" docker image inspect movie-service:1.0.0 ticket-service:1.0.0
check 'Les deux images Docker ont ete construites' jq -e 'length == 2 and all(.[]; (.RepoTags | length) > 0)' "$RUN_DIR/docker-images.json"
jq -r '.[] | "Image : \(.RepoTags | join(", ")) | utilisateur : \(.Config.User) | taille : \(.Size) octets"' "$RUN_DIR/docker-images.json"
wait_http "$MOVIE_URL/api/movies/whoami" 200 'Movie Compose demarre'
expect_json 'Environnement Compose' '.environment == "compose"'
wait_http "$TICKET_URL/actuator/health/readiness" 200 'Ticket Compose pret'
expect_http 'Reservation Compose' 201 "$TICKET_URL/api/tickets" '{"movieId":1,"seats":2}'
expect_json 'Total Compose : 21 euros' '.total == 21'
for service in movie ticket; do
    container=$(compose ps -q "$service")
    capture "$RUN_DIR/uid-$service.txt" docker exec "$container" id -u
    check "Conteneur $service : UID 10001" grep -qx 10001 "$RUN_DIR/uid-$service.txt"
done
capture "$RUN_DIR/compose-ps.txt" compose ps
capture "$RUN_DIR/compose.log" compose logs --no-color
run compose down
COMPOSE_STARTED=0

section 'Partie 4 — Minikube et communication inter-services'
log "Profil dedie : $PROFILE. Tous les kubectl utilisent explicitement ce contexte."
run minikube start -p "$PROFILE" --driver=docker --cpus=2 --memory=4096 --keep-context
CLUSTER_STARTED=1
run k --request-timeout=0 wait --for=condition=Ready node --all --timeout=180s
run minikube -p "$PROFILE" image load movie-service:1.0.0
run minikube -p "$PROFILE" image load ticket-service:1.0.0
run k apply --dry-run=client --validate=strict -f k8s/
run k apply -f k8s/00-namespace.yaml
run k apply -f k8s/10-config.yaml
# Rejouer l'etat initial de la partie 4, puis le changement de la partie 6.
run kn patch configmap movie-config --type=merge -p '{"data":{"MOVIE_ENVIRONMENT":"kubernetes"}}'
run k apply -f k8s/20-movie.yaml
run k apply -f k8s/30-ticket.yaml
# Relecture de l'image et de la ConfigMap meme lors d'une seconde execution.
run kn rollout restart deployment/movie deployment/ticket
wait_pods movie 2
wait_pods ticket 2
capture "$RUN_DIR/part4-pods.txt" kn get pods -o wide
capture "$RUN_DIR/part4-endpoints.json" kn get endpointslices -o json
check 'Deux endpoints movie prets' jq -e '[.items[] | select(.metadata.labels["kubernetes.io/service-name"] == "movie") | .endpoints[] | select(.conditions.ready)] | length == 2' "$RUN_DIR/part4-endpoints.json"
check 'Deux endpoints ticket prets' jq -e '[.items[] | select(.metadata.labels["kubernetes.io/service-name"] == "ticket") | .endpoints[] | select(.conditions.ready)] | length == 2' "$RUN_DIR/part4-endpoints.json"
capture "$RUN_DIR/inter-services.json" kn exec deployment/ticket -- wget -qO- http://movie:8080/api/movies/whoami
check 'DNS movie et communication interne' jq -e '.environment == "kubernetes" and (.hostname | startswith("movie-"))' "$RUN_DIR/inter-services.json"
start_forward cinema-exam ticket "$TICKET_PORT" "$RUN_DIR/forward-ticket.log"
TICKET_PF_PID=$FORWARD_PID
expect_http 'Readiness Kubernetes' 200 "$TICKET_URL/actuator/health/readiness"
expect_json 'Movie et readinessState UP' '.components.movie.status == "UP" and .components.readinessState.status == "UP"'
expect_http 'Reservation via port-forward ticket' 201 "$TICKET_URL/api/tickets" '{"movieId":2,"seats":2}'
expect_json 'Reservation Kubernetes : 24 euros' '.total == 24'

section 'Partie 5 — Ingress cinema.local'
run minikube -p "$PROFILE" addons enable ingress
run k --request-timeout=0 -n ingress-nginx wait pod -l app.kubernetes.io/component=controller --for=condition=Ready --timeout=240s
wait_ingress_admission k8s/40-ingress.yaml
run k apply -f k8s/40-ingress.yaml
capture "$RUN_DIR/ingress-description.txt" kn describe ingress cinema
start_forward ingress-nginx ingress-nginx-controller "$BASE_PORT" "$RUN_DIR/forward-ingress.log"
INGRESS_PF_PID=$FORWARD_PID
wait_http "$INGRESS_URL/api/movies" 200 'Ingress synchronise'
expect_json 'Quatre films a l affiche' 'length == 4'
expect_http 'Reservation via Ingress' 201 "$INGRESS_URL/api/tickets" '{"movieId":3,"seats":10}'
expect_json 'Total via Ingress : 90 euros' '.total == 90'
: > "$RUN_DIR/hostnames.txt"
# La repartition Ingress n'impose pas une alternance stricte des instances.
# Faire au moins six appels et laisser jusqu'a trente appels pour observer les deux.
for ((i=1; i<=30; i++)); do
    expect_http "Whoami Ingress $i" 200 "$INGRESS_URL/api/movies/whoami"
    printf '%s' "$HTTP_BODY" | jq -r .hostname >> "$RUN_DIR/hostnames.txt"
    distinct=$(sort -u "$RUN_DIR/hostnames.txt" | wc -l | tr -d ' ')
    if [ "$i" -ge 6 ] && [ "$distinct" -eq 2 ]; then break; fi
done
distinct=$(sort -u "$RUN_DIR/hostnames.txt" | wc -l | tr -d ' ')
check 'Deux Pods movie ont repondu' test "$distinct" -eq 2
expect_http 'Prefix accepte /api/movies/1' 200 "$INGRESS_URL/api/movies/1"
expect_http 'Actuator non expose par Ingress' 404 "$INGRESS_URL/actuator/health"

section 'Partie 6.1 — panne de movie et restauration'
capture "$RUN_DIR/ticket-before-failure.json" kn get pods -l app=ticket -o json
log 'Prediction : ticket non pret, endpoints non prets, Ingress 503 ; liveness UP et compteurs de redemarrage inchanges.'
MOVIE_DOWN=1
run kn scale deployment/movie --replicas=0
wait_http "$TICKET_URL/actuator/health/readiness" 503 'Ticket detecte la panne de movie'
wait_http "$INGRESS_URL/api/tickets" 503 'Ingress ne route plus vers ticket'
expect_http 'Liveness pendant la panne' 200 "$TICKET_URL/actuator/health/liveness"
expect_json 'Liveness reste UP pendant la panne' '.status == "UP"'
expect_http 'POST direct pendant la panne' 503 "$TICKET_URL/api/tickets" '{"movieId":1,"seats":1}'
capture "$RUN_DIR/ticket-after-failure.json" kn get pods -l app=ticket -o json
before_restarts=$(jq '[.items[].status.containerStatuses[].restartCount] | add' "$RUN_DIR/ticket-before-failure.json")
after_restarts=$(jq '[.items[].status.containerStatuses[].restartCount] | add' "$RUN_DIR/ticket-after-failure.json")
check 'Aucun redemarrage ticket provoque par la panne' test "$before_restarts" = "$after_restarts"
check 'Les deux Pods ticket sont non prets' jq -e 'all(.items[]; any(.status.conditions[]; .type == "Ready" and .status == "False"))' "$RUN_DIR/ticket-after-failure.json"
capture "$RUN_DIR/ticket-unready-endpoints.json" kn get endpointslices -l kubernetes.io/service-name=ticket -o json
check 'Aucun endpoint ticket pret' jq -e '[.items[].endpoints[]? | select(.conditions.ready)] | length == 0' "$RUN_DIR/ticket-unready-endpoints.json"
run kn scale deployment/movie --replicas=2
wait_pods movie 2
wait_pods ticket 2
MOVIE_DOWN=0
wait_http "$INGRESS_URL/api/tickets" 200 'Service retabli apres la panne'

section 'Partie 6.2 — les trois erreurs de ticket-debug'
# Le fichier rendu est corrige. Les erreurs de l'enonce sont recréees dans
# reports/, sans modifier broken/ticket-debug.yaml ni le code Java.
capture "$RUN_DIR/debug-correct.json" k create --dry-run=client -f broken/ticket-debug.yaml -o json
jq '.spec.template.spec.containers[0] |= (.imagePullPolicy="Always" | .envFrom[0].configMapRef.name="ticket-configmap" | .readinessProbe.httpGet.port=8081)' "$RUN_DIR/debug-correct.json" > "$RUN_DIR/debug-1.json"
DEBUG_CREATED=1
run k apply -f "$RUN_DIR/debug-1.json"
wait_debug_error 'ImagePullBackOff|ErrImagePull'
jq '.spec.template.spec.containers[0].imagePullPolicy="IfNotPresent"' "$RUN_DIR/debug-1.json" > "$RUN_DIR/debug-2.json"
run k apply -f "$RUN_DIR/debug-2.json"
wait_debug_error CreateContainerConfigError
jq '.spec.template.spec.containers[0].envFrom[0].configMapRef.name="ticket-config"' "$RUN_DIR/debug-2.json" > "$RUN_DIR/debug-3.json"
run k apply -f "$RUN_DIR/debug-3.json"
wait_debug_error Probe8081
run k apply -f broken/ticket-debug.yaml
wait_pods ticket-debug 1
run kn delete deployment ticket-debug
DEBUG_CREATED=0

section 'Partie 6.3 — ConfigMap sans reconstruction'
expect_http 'Environnement avant modification' 200 "$INGRESS_URL/api/movies/whoami"
expect_json 'Environnement initial kubernetes' '.environment == "kubernetes"'
run k apply -f k8s/10-config.yaml
expect_http 'Processus existant apres modification de la ConfigMap' 200 "$INGRESS_URL/api/movies/whoami"
expect_json 'Les variables existantes ne sont pas rechargees' '.environment == "kubernetes"'
run kn rollout restart deployment/movie
wait_pods movie 2
for i in 1 2 3 4; do
    expect_http "Configuration du nouveau Pod $i" 200 "$INGRESS_URL/api/movies/whoami"
    expect_json 'Environnement production sans rebuild' '.environment == "production"'
done

section 'Partie 7 — donnees en memoire et remplacement des Pods'
for i in 1 2 3 4; do expect_http "Reservation en memoire $i" 201 "$INGRESS_URL/api/tickets" '{"movieId":1,"seats":1}'; done
ticket_pods=$(kn get pods -l app=ticket -o json | jq -r '.items[].metadata.name')
total=0
for pod in $ticket_pods; do
    capture "$RUN_DIR/reservations-$pod.json" kn exec "$pod" -- wget -qO- http://localhost:8080/api/tickets
    count=$(jq length "$RUN_DIR/reservations-$pod.json"); total=$((total + count))
done
# Un total impair garantit des listes de tailles differentes entre deux Pods.
if [ "$((total % 2))" -eq 0 ]; then
    expect_http 'Reservation supplementaire sur une instance' 201 "$TICKET_URL/api/tickets" '{"movieId":1,"seats":1}'
fi
: > "$RUN_DIR/reservation-counts.txt"
for ((i=1; i<=30; i++)); do
    expect_http "Lecture de la liste $i" 200 "$INGRESS_URL/api/tickets"
    printf '%s' "$HTTP_BODY" | jq length >> "$RUN_DIR/reservation-counts.txt"
    count_variations=$(sort -u "$RUN_DIR/reservation-counts.txt" | wc -l | tr -d ' ')
    if [ "$i" -ge 8 ] && [ "$count_variations" -eq 2 ]; then break; fi
done
count_variations=$(sort -u "$RUN_DIR/reservation-counts.txt" | wc -l | tr -d ' ')
check 'Les listes ticket varient entre les instances' test "$count_variations" -eq 2
old_movie=$(kn get pods -l app=movie -o json | jq -r '.items[0].metadata.name')
run kn delete pod "$old_movie" --wait=false
wait_pods movie 2
# Les variables sont interpretees par le sous-shell, pas par le shell appelant.
# shellcheck disable=SC2016
check 'Le Pod supprime a ete remplace' bash -c '! grep -q -- "$1" "$2"' _ "$old_movie" "$RUN_DIR/pods-movie.json"
stop_pid "$TICKET_PF_PID"; TICKET_PF_PID=''
log 'Suppression des Pods ticket du profil de demonstration pour observer la perte des donnees en memoire.'
run kn delete pods -l app=ticket --wait=false
wait_pods ticket 2
ticket_pods=$(kn get pods -l app=ticket -o json | jq -r '.items[].metadata.name')
for pod in $ticket_pods; do
    capture "$RUN_DIR/empty-$pod.json" kn exec "$pod" -- wget -qO- http://localhost:8080/api/tickets
    check "Reservations perdues apres remplacement : $pod" jq -e 'length == 0' "$RUN_DIR/empty-$pod.json"
done
log 'La solution architecturale est une base persistante partagee ; voir Q7.2 dans reponses.md.'

section 'Bonus B1 — controle de la securite appliquee'
capture "$RUN_DIR/security-pods.json" kn get pods -l app=movie -o json
# $s est une variable jq, pas une variable Bash.
# shellcheck disable=SC2016
check 'SecurityContext et /tmp sur tous les Pods movie' jq -e 'all(.items[];
    .spec.containers[0].securityContext as $s |
    $s.runAsUser == 10001 and $s.runAsNonRoot == true and $s.allowPrivilegeEscalation == false and
    $s.readOnlyRootFilesystem == true and ($s.capabilities.drop | index("ALL")) != null and
    any(.spec.containers[0].volumeMounts[]; .name == "tmp" and .mountPath == "/tmp") and
    any(.spec.volumes[]; .name == "tmp" and .emptyDir != null))' "$RUN_DIR/security-pods.json"
movie_pods=$(jq -r '.items[].metadata.name' "$RUN_DIR/security-pods.json")
for pod in $movie_pods; do
    capture "$RUN_DIR/uid-$pod.txt" kn exec "$pod" -- id -u
    check "UID 10001 : $pod" grep -qx 10001 "$RUN_DIR/uid-$pod.txt"
    command_log kn exec "$pod" -- touch /test
    if kn exec "$pod" -- touch /test > "$RUN_DIR/readonly-$pod.txt" 2>&1; then
        fail "Racine en lecture seule : $pod" 'Ecriture de /test acceptee.'
    fi
    check "Ecriture de /test refusee : $pod" grep -qi 'Read-only file system' "$RUN_DIR/readonly-$pod.txt"
done

section 'Bonus B2 — 300 requetes pendant le rolling update'
capture "$RUN_DIR/rolling-strategy.json" kn get deployment movie -o json
check 'Strategie maxUnavailable=0 et maxSurge=1' jq -e '.spec.strategy.type == "RollingUpdate" and .spec.strategy.rollingUpdate.maxUnavailable == 0 and .spec.strategy.rollingUpdate.maxSurge == 1' "$RUN_DIR/rolling-strategy.json"
: > "$RUN_DIR/traffic.tsv"
(
    for ((i=1; i<=300; i++)); do
        rc=0
        sample=$(curl --noproxy '*' --silent --show-error --connect-timeout 3 --max-time 10 \
            --header 'Host: cinema.local' -o /dev/null -w '%{http_code}' "$INGRESS_URL/api/movies") || rc=$?
        printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$i" "${sample:-000}" "$rc" >> "$RUN_DIR/traffic.tsv"
        if [ "$i" -eq 1 ]; then : > "$RUN_DIR/traffic-started"; fi
        sleep 0.2
    done
) > "$RUN_DIR/traffic-errors.log" 2>&1 &
TRAFFIC_PID=$!
deadline=$((SECONDS + 30))
while [ ! -f "$RUN_DIR/traffic-started" ]; do
    if ! kill -0 "$TRAFFIC_PID" 2>/dev/null || [ "$SECONDS" -ge "$deadline" ]; then fail 'Demarrage de la boucle HTTP'; fi
    sleep 0.2
done
rollout_start=$(date +%s)
run kn rollout restart deployment/movie
run kn --request-timeout=0 rollout status deployment/movie --timeout=240s
rollout_end=$(date +%s)
log 'Rollout termine. Attente du bilan des 300 requetes...'
while kill -0 "$TRAFFIC_PID" 2>/dev/null; do printf '.'; sleep 2; done
if ! wait "$TRAFFIC_PID"; then fail 'Boucle de trafic interrompue'; fi
TRAFFIC_PID=''
printf '\n'
samples=$(wc -l < "$RUN_DIR/traffic.tsv" | tr -d ' ')
check 'Exactement 300 requetes executees' test "$samples" -eq 300
# $3 et $4 designent les colonnes awk.
# shellcheck disable=SC2016
check '300 reponses HTTP 200 sans erreur curl' awk -F '\t' '$3 != "200" || $4 != "0" {bad=1} END {exit bad}' "$RUN_DIR/traffic.tsv"
first_request=$(awk -F '\t' 'NR==1 {print $1}' "$RUN_DIR/traffic.tsv")
last_request=$(awk -F '\t' 'END {print $1}' "$RUN_DIR/traffic.tsv")
check 'Trafic commence avant le rollout' test "$first_request" -le "$rollout_start"
check 'Trafic maintenu jusqu a la fin du rollout' test "$last_request" -ge "$rollout_end"
printf 'Premiere requete : %s\nDebut rollout : %s\nFin rollout : %s\nDerniere requete : %s\n' "$first_request" "$rollout_start" "$rollout_end" "$last_request" > "$RUN_DIR/rolling-times.txt"
wait_pods movie 2
wait_pods ticket 2

section 'Bilan — toutes les etapes sont terminees'
expect_http 'Verification HTTP finale' 200 "$INGRESS_URL/api/movies"
log "Toutes les verifications ont reussi : $PASSED. Les rapports Maven sont aussi conserves."
log "Le cluster $PROFILE reste disponible pour inspection."
log "Pour rouvrir l'acces : kubectl --context $PROFILE -n ingress-nginx port-forward --address 127.0.0.1 svc/ingress-nginx-controller $BASE_PORT:80"
log "Puis : curl -H 'Host: cinema.local' $INGRESS_URL/api/movies"
log "Pour supprimer uniquement ce cluster de demonstration : minikube delete -p $PROFILE"
