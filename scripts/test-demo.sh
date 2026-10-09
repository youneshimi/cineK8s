#!/usr/bin/env bash
# Tests des garde-fous et de la gestion des erreurs, sans Docker ni Kubernetes.
# Les modifications de RUN_DIR dans les sous-shells isolent leurs rapports.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RUN_DIR="$ROOT_DIR/reports/self-tests-$$"
mkdir -p "$RUN_DIR"
STAGE='Tests du script'; PASSED=0; FAILED=0; START_SECONDS=$SECONDS; START_DATE='test'
PROFILE=cinek8s-demo-test
BLUE=''; GREEN=''; RED=''; RESET=''
INGRESS_URL=http://127.0.0.1:18080
MOVIE_PID=''; TICKET_PID=''; TICKET_PF_PID=''; INGRESS_PF_PID=''; TRAFFIC_PID=''
FORWARD_PID=''; MOVIE_DOWN=0; DEBUG_CREATED=0; COMPOSE_STARTED=0; CLUSTER_STARTED=0
: > "$RUN_DIR/checks.tsv"; : > "$RUN_DIR/commands.log"; : > "$RUN_DIR/http.log"
# shellcheck source=scripts/demo-lib.sh
source "$ROOT_DIR/scripts/demo-lib.sh"

assert() {
    if "$@"; then printf '[TEST OK] %s\n' "$*"; else printf '[TEST ECHEC] %s\n' "$*" >&2; exit 1; fi
}

# Simuler un outil qui ecrit sa configuration : seul le fichier de la demo
# doit recevoir cette ecriture, meme si l'utilisateur avait defini KUBECONFIG.
(
    RUN_DIR="$RUN_DIR/kubeconfig-isolation"
    mkdir -p "$RUN_DIR"
    printf 'Configuration utilisateur conservee\n' > "$RUN_DIR/user-config"
    export KUBECONFIG="$RUN_DIR/user-config"
    prepare_kubeconfig
    # Fonction invoquee par k, sans lancer un vrai kubectl.
    # shellcheck disable=SC2329
    kubectl() {
        local destination=${KUBECONFIG:-} arg
        while [ "$#" -gt 0 ]; do
            arg=$1; shift
            if [ "$arg" = --kubeconfig ]; then destination=$1; shift; fi
        done
        printf 'Configuration de demonstration\n' >> "$destination"
    }
    k get pods
    bash -c 'printf "Ecriture du processus enfant\n" >> "$KUBECONFIG"'
    assert grep -qx 'Configuration utilisateur conservee' "$RUN_DIR/user-config"
    assert test "$(wc -l < "$RUN_DIR/user-config")" -eq 1
    assert grep -q 'Configuration de demonstration' "$RUN_DIR/kubeconfig"
    assert grep -q 'Ecriture du processus enfant' "$RUN_DIR/kubeconfig"
)

assert bash -n "$ROOT_DIR/demo.sh"
assert bash -n "$ROOT_DIR/scripts/demo-lib.sh"
assert bash "$ROOT_DIR/demo.sh" --help

for invalid in '--profile minikube' '--profile production' '--port-base 80' '--port-base 65530' '--port-base texte' '--inconnu'; do
    # Les arguments de ces cas de test sont volontairement separes.
    # shellcheck disable=SC2086
    if bash "$ROOT_DIR/demo.sh" $invalid > "$RUN_DIR/invalid.txt" 2>&1; then
        printf 'Argument dangereux accepte : %s\n' "$invalid" >&2; exit 1
    else
        assert test "$?" -eq 2
    fi
done

assert test "$(html_escape '<script>&"')" = '&lt;script&gt;&amp;&quot;'
record OK 'Un test positif' 'Exemple <non interprete>'
write_report 0
assert grep -q 'Demonstration reussie' "$RUN_DIR/resume.txt"
assert grep -q 'Exemple &lt;non interprete&gt;' "$RUN_DIR/rapport.html"
record ECHEC 'Un echec attendu dans le test' 'Cause <detail>'
write_report 1
assert grep -q 'Demonstration interrompue' "$RUN_DIR/resume.txt"
assert grep -q 'Cause &lt;detail&gt;' "$RUN_DIR/rapport.html"

# Simuler uniquement le transport HTTP : un HTTP 503 est une reponse,
# un timeout curl est un echec reseau et ne doit pas etre traite comme un 200.
curl() {
    local output='' arg
    while [ "$#" -gt 0 ]; do
        arg=$1; shift
        if [ "$arg" = -o ]; then output=$1; shift; fi
    done
    printf '{"status":"DOWN"}' > "$output"
    printf '%s' "${FAKE_HTTP_CODE:-503}"
    return "${FAKE_CURL_EXIT:-0}"
}
FAKE_HTTP_CODE=503; FAKE_CURL_EXIT=0
assert request "$INGRESS_URL/api/tickets"
assert test "$HTTP_CODE" = 503
expect_http 'HTTP 503 attendu' 503 "$INGRESS_URL/api/tickets"
FAKE_HTTP_CODE=000; FAKE_CURL_EXIT=28
if request "$INGRESS_URL/api/movies"; then printf 'Timeout masque.\n' >&2; exit 1; fi
if (expect_http 'Timeout inattendu' 200 "$INGRESS_URL/api/movies"); then
    printf 'Le timeout doit faire echouer la verification.\n' >&2; exit 1
fi

if command -v jq >/dev/null; then
    HTTP_BODY='{"status":"DOWN"}'
    expect_json 'JSON conforme a l etat attendu' '.status == "DOWN"'
    if (expect_json 'JSON avec un etat incorrect' '.status == "UP"'); then
        printf 'Le mauvais etat JSON doit faire echouer le test.\n' >&2; exit 1
    fi
    # Le noeud Ready ne suffit pas : les deux composants reseau doivent exister
    # et etre prets avant d'accepter un cluster comme utilisable.
    network_calls=0
    k() {
        network_calls=$((network_calls + 1))
        case "$network_calls" in
            1) printf '%s\n' '{"items":[]}' ;;
            2) printf '%s\n' '{"items":[{"metadata":{"labels":{"k8s-app":"kube-dns"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' ;;
            3) printf '%s\n' '{"items":[{"metadata":{"labels":{"k8s-app":"kube-dns"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"labels":{"k8s-app":"kube-proxy"}},"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}' ;;
            *) printf '%s\n' '{"items":[{"metadata":{"labels":{"k8s-app":"kube-dns"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"labels":{"k8s-app":"kube-proxy"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' ;;
        esac
    }
    sleep() { :; }
    wait_cluster_network
    assert test "$network_calls" -eq 4
    unset -f sleep
    # Ni un Pod terminating ni un nombre insuffisant de Pods ne doivent
    # etre acceptes comme un deploiement termine.
    pod_calls=0
    k() {
        pod_calls=$((pod_calls + 1))
        case "$pod_calls" in
            1) printf '%s\n' '{"items":[{"metadata":{"deletionTimestamp":"test"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' ;;
            2) printf '%s\n' '{"items":[{"metadata":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' ;;
            *) printf '%s\n' '{"items":[{"metadata":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' ;;
        esac
    }
    sleep() { :; }
    wait_pods movie 2
    assert test "$pod_calls" -eq 3
    unset -f sleep
else
    printf '[TEST NON EXECUTE] Tests des expressions JSON : jq absent.\n'
fi

# Un cluster en panne doit produire un echec et conserver les logs du crash.
if command -v jq >/dev/null; then
    network_dir="$RUN_DIR/network-timeout"
    mkdir -p "$network_dir"
    network_code=0
    (
        RUN_DIR=$network_dir
        : > "$RUN_DIR/checks.tsv"; : > "$RUN_DIR/commands.log"
        k() {
            case "$*" in
                *'get pods'*'-o json'*)
                    printf '%s\n' '{"items":[]}'
                    SECONDS=$((SECONDS + 181)) ;;
                *'describe pods'*) printf 'State: CrashLoopBackOff\n' ;;
                *'logs'*'--previous'*) printf 'Previous kube-proxy startup error\n' ;;
                *) printf 'Network diagnostic simulated\n' ;;
            esac
        }
        sleep() { :; }
        wait_cluster_network
    ) > "$network_dir/output.txt" 2>&1 || network_code=$?
    assert test "$network_code" -eq 1
    assert grep -q CrashLoopBackOff "$network_dir/network-describe.txt"
    assert grep -q 'Previous kube-proxy startup error' "$network_dir/network-kube-proxy-previous.log"
fi

# Un delai depasse doit rester un echec, avec la cause de demarrage et
# les logs precedents disponibles. L'API et l'horloge sont simulees ici.
if command -v jq >/dev/null; then
    timeout_dir="$RUN_DIR/pod-timeout"
    mkdir -p "$timeout_dir"
    timeout_code=0
    (
        RUN_DIR=$timeout_dir
        : > "$RUN_DIR/checks.tsv"; : > "$RUN_DIR/commands.log"
        k() {
            case "$*" in
                *'get pods'*'-o json'*)
                    printf '%s\n' '{"items":[{"metadata":{"name":"movie-test"},"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}'
                    SECONDS=$((SECONDS + 901)) ;;
                *'describe pods'*) printf 'Reason: FailedMount\n' ;;
                *'logs'*'--previous'*) printf 'Previous startup error\n' ;;
                *) printf 'Diagnostic simulated\n' ;;
            esac
        }
        sleep() { :; }
        wait_pods movie 2
    ) > "$timeout_dir/output.txt" 2>&1 || timeout_code=$?
    assert test "$timeout_code" -eq 1
    assert grep -q FailedMount "$timeout_dir/diagnostic-movie-describe.txt"
    assert grep -q 'Previous startup error' "$timeout_dir/diagnostic-movie-test-previous.log"
fi

# Le webhook peut refuser une connexion pendant son demarrage. Une erreur
# de validation de l'Ingress, elle, doit arreter le script immediatement.
admission_calls=0
k() {
    admission_calls=$((admission_calls + 1))
    if [ "$admission_calls" -lt 3 ]; then
        printf '%s\n' 'failed calling webhook "validate.nginx.ingress.kubernetes.io": failed to call webhook: connect: connection refused' >&2
        return 1
    fi
    printf 'ingress/cinema created (server dry run)\n'
}
sleep() { :; }
wait_ingress_admission k8s/40-ingress.yaml
assert test "$admission_calls" -eq 3
k() { printf 'Error: ingress rejected: invalid path\n' >&2; return 1; }
if (wait_ingress_admission k8s/40-ingress.yaml); then
    printf 'Une erreur de validation a ete ignoree.\n' >&2; exit 1
fi
unset -f sleep

# Le trafic doit couvrir aussi un rollout plus long que les 300 premiers appels.
# Les erreurs HTTP et reseau sont conservees, jamais remplacees par un succes.
for scenario in rapide lent erreurs; do
    traffic_dir="$RUN_DIR/traffic-$scenario"
    mkdir -p "$traffic_dir"
    (
        RUN_DIR=$traffic_dir
        : > "$RUN_DIR/traffic.tsv"
        if [ "$scenario" = rapide ]; then : > "$RUN_DIR/rollout-finished"; fi
        printf '0\n' > "$RUN_DIR/count.txt"
        sleep() { :; }
        date() { printf '12345\n'; }
        curl() {
            local call
            read -r call < "$RUN_DIR/count.txt"
            call=$((call + 1))
            printf '%s\n' "$call" > "$RUN_DIR/count.txt"
            if [ "$call" -eq 350 ]; then : > "$RUN_DIR/rollout-finished"; fi
            if [ "$scenario" = erreurs ]; then
                case "$call" in
                    2) printf 503; return 0 ;;
                    3) printf 000; return 28 ;;
                esac
            fi
            printf 200
        }
        sample_rollout_traffic
    )
    assert test -f "$traffic_dir/traffic-started"
    if [ "$scenario" = rapide ]; then
        assert test "$(wc -l < "$traffic_dir/traffic.tsv")" -eq 300
    else
        # Le marqueur apparait pendant l'appel 350 : l'appel 351 suit sa creation.
        assert test "$(wc -l < "$traffic_dir/traffic.tsv")" -eq 351
    fi
    if [ "$scenario" = erreurs ]; then
        # $3 et $4 sont les colonnes awk, pas des variables du shell.
        # shellcheck disable=SC2016
        assert awk -F '\t' 'NR==2 {if ($3 != "503" || $4 != 0) exit 1} NR==3 {if ($3 != "000" || $4 != 28) exit 1}' "$traffic_dir/traffic.tsv"
        # shellcheck disable=SC2016
        if awk -F '\t' '$3 != "200" || $4 != "0" {bad=1} END {exit bad}' "$traffic_dir/traffic.tsv"; then
            printf 'Erreurs de trafic masquees.\n' >&2; exit 1
        fi
    fi
done

# Un port-forward demarre par le script doit etre arrete, y compris si
# sa preparation echoue. Les autres processus ne sont pas vises.
k() { printf 'Forwarding from 127.0.0.1:18080 -> 80\n'; sleep 30; }
start_forward ingress-nginx ingress-nginx-controller 18080 "$RUN_DIR/fake-forward.log"
assert test "$INGRESS_PF_PID" = "$FORWARD_PID"
assert kill -0 "$INGRESS_PF_PID"
stop_pid "$INGRESS_PF_PID"
if kill -0 "$INGRESS_PF_PID" 2>/dev/null; then printf 'Processus non arrete.\n' >&2; exit 1; fi
INGRESS_PF_PID=''

# Les colonnes conservees dans le rapport ne doivent pas etre corrompues
# par des tabulations ou des retours a la ligne dans les sorties.
record OK $'Titre\tavec\nretour' $'Detail\tavec\nretour'
assert awk -F '\t' 'NF < 3 || NF > 4 {bad=1} END {exit bad}' "$RUN_DIR/checks.tsv"

# Le nettoyage ne doit pas transformer un echec en succes. La restauration
# de movie et la suppression du debug sont ici simulees, sans kubectl reel.
cleanup_dir="$RUN_DIR/cleanup-test"
mkdir -p "$cleanup_dir"
cleanup_code=0
(
    RUN_DIR=$cleanup_dir
    FAILED=0; PASSED=0; MOVIE_DOWN=1; DEBUG_CREATED=1; COMPOSE_STARTED=1
    : > "$RUN_DIR/checks.tsv"
    # Fonctions invoquees indirectement par le trap finish.
    # shellcheck disable=SC2329
    k() { printf 'kubectl %s\n' "$*" >> "$RUN_DIR/cleanup-calls.txt"; }
    # shellcheck disable=SC2329
    compose() { printf 'compose %s\n' "$*" >> "$RUN_DIR/cleanup-calls.txt"; }
    trap finish EXIT
    exit 9
) > "$RUN_DIR/cleanup-test-output.txt" 2>&1 || cleanup_code=$?
assert test "$cleanup_code" -eq 9
assert grep -q 'scale deployment/movie --replicas=2' "$cleanup_dir/cleanup-calls.txt"
assert grep -q 'delete deployment ticket-debug --ignore-not-found' "$cleanup_dir/cleanup-calls.txt"
assert grep -q 'compose down' "$cleanup_dir/cleanup-calls.txt"
assert grep -q 'Demonstration interrompue' "$cleanup_dir/resume.txt"
printf '\nTests du script termines. Aucun cluster ni conteneur cree.\n'
