#!/usr/bin/env bash
# Fonctions communes. Compatible avec Bash 3.2 (macOS) et Bash 4+ (Linux).

log() {
    printf '%s\n' "$*" | tee -a "$RUN_DIR/console.log"
}

section() {
    STAGE=$1
    printf '\n%s============================================================%s\n' "$BLUE" "$RESET"
    printf '%s  %s%s\n' "$BLUE" "$STAGE" "$RESET"
    printf '%s============================================================%s\n' "$BLUE" "$RESET"
    printf '\n=== %s ===\n' "$STAGE" >> "$RUN_DIR/console.log"
}

record() {
    local status=$1 title=$2 detail=${3:-}
    # Le TSV reste exploitable meme si une commande produit plusieurs lignes.
    title=${title//$'\t'/ }; title=${title//$'\n'/ }
    detail=${detail//$'\t'/ }; detail=${detail//$'\n'/ }
    printf '%s\t%s\t%s\t%s\n' "$STAGE" "$status" "$title" "$detail" >> "$RUN_DIR/checks.tsv"
    if [ "$status" = OK ]; then
        PASSED=$((PASSED + 1))
        printf '%s[OK]%s %s %s\n' "$GREEN" "$RESET" "$title" "$detail"
    else
        FAILED=$((FAILED + 1))
        printf '%s[ECHEC]%s %s %s\n' "$RED" "$RESET" "$title" "$detail" >&2
    fi
    printf '[%s] %s %s\n' "$status" "$title" "$detail" >> "$RUN_DIR/console.log"
}

fail() { record ECHEC "$1" "${2:-Consulter les logs.}"; exit 1; }

check() {
    local title=$1
    shift
    if "$@"; then record OK "$title"; else fail "$title"; fi
}

command_log() {
    {
        printf '\n$'
        printf ' %q' "$@"
        printf '\n'
    } >> "$RUN_DIR/commands.log"
}

run() {
    command_log "$@"
    if "$@" 2>&1 | tee -a "$RUN_DIR/commands.log"; then
        return 0
    else
        fail "Commande en echec" "$*"
    fi
}

capture() {
    local destination=$1
    shift
    command_log "$@"
    if "$@" > "$destination" 2>> "$RUN_DIR/commands.log"; then
        cat "$destination" >> "$RUN_DIR/commands.log"
    else
        fail "Commande en echec" "$*"
    fi
}

# Le contexte et le namespace sont explicites pour chaque commande Kubernetes.
k() { kubectl --context "$PROFILE" --request-timeout=20s "$@"; }
kn() { k -n cinema-exam "$@"; }
compose() { docker compose --project-name "$PROFILE" -f "$RUN_DIR/compose.json" "$@"; }

request() {
    local url=$1 payload=${2:-} result rc=0
    local args=(--noproxy '*' --silent --show-error --connect-timeout 3 --max-time 10
        -o "$RUN_DIR/last-body.json" -w '%{http_code}')
    case "$url" in
        "$INGRESS_URL"/*) args+=(--header 'Host: cinema.local') ;;
    esac
    if [ -n "$payload" ]; then args+=(--header 'Content-Type: application/json' --data-binary "$payload"); fi
    : > "$RUN_DIR/last-body.json"
    result=$(curl "${args[@]}" "$url" 2>> "$RUN_DIR/http-errors.log") || rc=$?
    HTTP_CODE=${result:-000}
    HTTP_BODY=$(cat "$RUN_DIR/last-body.json" 2>/dev/null || true)
    printf '%s %s curl=%s\n%s\n' "$url" "$HTTP_CODE" "$rc" "$HTTP_BODY" >> "$RUN_DIR/http.log"
    return "$rc"
}

expect_http() {
    local title=$1 code=$2 url=$3 payload=${4:-}
    if ! request "$url" "$payload"; then fail "$title" "Erreur reseau, HTTP $HTTP_CODE."; fi
    check "$title : HTTP $code" test "$HTTP_CODE" = "$code"
}

expect_json() {
    local title=$1 expression=$2
    if printf '%s' "$HTTP_BODY" | jq -e "$expression" >/dev/null; then
        record OK "$title" "$HTTP_BODY"
    else
        fail "$title" "$HTTP_BODY"
    fi
}

wait_http() {
    local url=$1 code=$2 title=$3 deadline=$((SECONDS + 180))
    log "Attente : $title"
    while [ "$SECONDS" -lt "$deadline" ]; do
        if request "$url" && [ "$HTTP_CODE" = "$code" ]; then record OK "$title"; return; fi
        sleep 2
    done
    fail "$title" "Delai de 180 secondes depasse ; HTTP $HTTP_CODE."
}

collect_pod_diagnostics() {
    local app=$1 pod
    log "Diagnostics des Pods $app : $RUN_DIR/diagnostic-$app-*"
    # Ces lectures ne doivent pas masquer la cause initiale si l'API repond mal.
    kn get pods -l "app=$app" -o wide > "$RUN_DIR/diagnostic-$app-pods.txt" 2>&1 || true
    kn describe pods -l "app=$app" > "$RUN_DIR/diagnostic-$app-describe.txt" 2>&1 || true
    kn get events --sort-by=.lastTimestamp > "$RUN_DIR/diagnostic-$app-events.txt" 2>&1 || true
    kn get deployment "$app" -o json > "$RUN_DIR/diagnostic-$app-deployment.json" 2>&1 || true
    k describe nodes > "$RUN_DIR/diagnostic-$app-nodes.txt" 2>&1 || true
    if [ -s "$RUN_DIR/pods-$app.json" ]; then
        jq -r '.items[].metadata.name // empty' "$RUN_DIR/pods-$app.json" \
            > "$RUN_DIR/diagnostic-$app-names.txt" 2>/dev/null || true
        while IFS= read -r pod; do
            pod=${pod%$'\r'}
            [ -n "$pod" ] || continue
            kn logs "$pod" --all-containers=true --tail=120 \
                > "$RUN_DIR/diagnostic-$pod-current.log" 2>&1 || true
            kn logs "$pod" --all-containers=true --previous --tail=120 \
                > "$RUN_DIR/diagnostic-$pod-previous.log" 2>&1 || true
        done < "$RUN_DIR/diagnostic-$app-names.txt"
    fi
    cat "$RUN_DIR/diagnostic-$app-pods.txt"
    tail -n 15 "$RUN_DIR/diagnostic-$app-events.txt"
}

wait_pods() {
    local app=$1 count=$2 deadline=$((SECONDS + 900))
    log "Attente de $count Pod(s) $app prets..."
    while [ "$SECONDS" -lt "$deadline" ]; do
        if kn get pods -l "app=$app" -o json > "$RUN_DIR/pods-$app.json" 2>> "$RUN_DIR/commands.log" &&
            jq -e --argjson count "$count" '
                (.items | length) == $count and
                all(.items[]; .metadata.deletionTimestamp == null and
                    any(.status.conditions[]?; .type == "Ready" and .status == "True"))
            ' "$RUN_DIR/pods-$app.json" >/dev/null; then
            record OK "$count Pod(s) $app prets"
            return
        fi
        sleep 2
    done
    collect_pod_diagnostics "$app"
    fail "Pods $app" "Delai de 900 secondes depasse. Consulter diagnostic-$app-describe.txt et les logs diagnostic-*-previous.log."
}

sample_rollout_traffic() {
    local i=1 rc sample rollout_done
    while :; do
        rollout_done=0
        # Une derniere requete doit commencer apres la fin observee du rollout.
        if [ -f "$RUN_DIR/rollout-finished" ]; then rollout_done=1; fi
        rc=0
        sample=$(curl --noproxy '*' --silent --show-error --connect-timeout 3 --max-time 10 \
            --header 'Host: cinema.local' -o /dev/null -w '%{http_code}' "$INGRESS_URL/api/movies") || rc=$?
        printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$i" "${sample:-000}" "$rc" >> "$RUN_DIR/traffic.tsv"
        if [ "$i" -eq 1 ]; then : > "$RUN_DIR/traffic-started"; fi
        if [ "$i" -ge 300 ] && [ "$rollout_done" -eq 1 ]; then break; fi
        sleep 0.2
        i=$((i + 1))
    done
}

stop_pid() {
    local pid=${1:-} deadline=$((SECONDS + 35))
    [ -n "$pid" ] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
        if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
    fi
    wait "$pid" 2>/dev/null || true
}

start_forward() {
    local namespace=$1 service=$2 port=$3 destination=$4 deadline=$((SECONDS + 60)) remote_port=8080
    if [ "$namespace" = ingress-nginx ]; then
        remote_port=80
    fi
    k -n "$namespace" port-forward --address 127.0.0.1 "svc/$service" "$port:$remote_port" > "$destination" 2>&1 &
    FORWARD_PID=$!
    # Enregistrer le PID avant l'attente, pour le nettoyer meme en cas d'echec.
    if [ "$namespace" = ingress-nginx ]; then INGRESS_PF_PID=$FORWARD_PID; else TICKET_PF_PID=$FORWARD_PID; fi
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ! kill -0 "$FORWARD_PID" 2>/dev/null; then cat "$destination" >&2; fail 'Port-forward' "$service"; fi
        if grep -q 'Forwarding from' "$destination"; then return; fi
        sleep 1
    done
    fail 'Port-forward' "Impossible de joindre $service en 60 secondes."
}

wait_ingress_admission() {
    local manifest=$1 deadline=$((SECONDS + 180))
    local diagnosis="$RUN_DIR/ingress-admission.log"
    log 'Attente de la validation Ingress par le serveur Kubernetes...'
    while [ "$SECONDS" -lt "$deadline" ]; do
        command_log k apply --dry-run=server -f "$manifest"
        # Le Pod Ready ne garantit pas encore la connexion au webhook.
        # Cette validation appelle le vrai webhook, sans creer de ressource.
        if k apply --dry-run=server -f "$manifest" > "$diagnosis" 2>&1; then
            cat "$diagnosis" >> "$RUN_DIR/commands.log"
            record OK 'Webhook Ingress disponible et manifest valide par le serveur'
            return
        fi
        cat "$diagnosis" >> "$RUN_DIR/commands.log"
        # Reessayer uniquement les erreurs de connexion de ce webhook.
        # Une erreur YAML, RBAC ou un refus de validation reste un echec.
        if ! grep -q 'failed calling webhook "validate.nginx.ingress.kubernetes.io"' "$diagnosis" ||
            ! grep -Eq 'connection refused|no endpoints available|i/o timeout|context deadline exceeded|Client.Timeout exceeded' "$diagnosis"; then
            cat "$diagnosis" >&2
            fail 'Validation serveur de l Ingress' 'Erreur de validation ; consulter ingress-admission.log.'
        fi
        sleep 2
    done
    fail 'Webhook Ingress disponible' 'Delai de 180 secondes depasse ; consulter ingress-admission.log.'
}

wait_debug_error() {
    local expected=$1 deadline=$((SECONDS + 360)) pod
    while [ "$SECONDS" -lt "$deadline" ]; do
        kn get pods -l app=ticket-debug -o json > "$RUN_DIR/debug-pods.json"
        if [ "$expected" = Probe8081 ]; then
            pod=$(jq -r '.items | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty' "$RUN_DIR/debug-pods.json")
            if [ -n "$pod" ]; then
                kn get events --field-selector "involvedObject.name=$pod" -o json > "$RUN_DIR/debug-events.json"
                if jq -e 'any(.items[]; .reason == "Unhealthy" and (.message | contains("8081")))' "$RUN_DIR/debug-events.json" >/dev/null; then
                    record OK 'Readiness sur le mauvais port observee' "$pod : 8081"
                    capture "$RUN_DIR/debug-probe.txt" kn describe pod "$pod"
                    return
                fi
            fi
        elif jq -e --arg expected "$expected" 'any(.items[].status.containerStatuses[]?;
            (.state.waiting.reason // "") | test($expected))' "$RUN_DIR/debug-pods.json" >/dev/null; then
            record OK "Erreur attendue observee : $expected"
            capture "$RUN_DIR/debug-$expected.txt" kn describe pods -l app=ticket-debug
            return
        fi
        sleep 2
    done
    fail "Erreur attendue : $expected" 'Non observee en 360 secondes.'
}

html_escape() {
    local value=$1
    value=${value//&/\&amp;}; value=${value//</\&lt;}; value=${value//>/\&gt;}
    value=${value//\"/\&quot;}
    printf '%s' "$value"
}

write_report() {
    local status=$1 stage verdict title detail outcome
    local elapsed=$((SECONDS - START_SECONDS))
    [ "$status" -eq 0 ] && outcome='Demonstration reussie' || outcome='Demonstration interrompue'
    {
        cat <<'HTML'
<!doctype html><html lang="fr"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CineK8s — rapport de demonstration</title>
<style>
body{margin:0;background:#101826;color:#e7edf6;font:16px/1.6 system-ui,sans-serif}
main{max-width:1120px;margin:48px auto;padding:0 24px}h1{font-size:2.3rem;margin-bottom:8px}
.intro{color:#a7b7cf}.cards{display:flex;gap:16px;flex-wrap:wrap;margin:28px 0}
.card{background:#1c293e;border:1px solid #31425c;border-radius:12px;padding:18px 24px}
.card strong{display:block;font-size:1.8rem}table{width:100%;border-collapse:collapse}
th,td{padding:12px;text-align:left;border-bottom:1px solid #31425c;vertical-align:top}
th{color:#a7b7cf}td:last-child{overflow-wrap:anywhere;max-width:450px;font-size:.9rem}
.OK{color:#62dfac}.ECHEC{color:#ff9696}a{color:#86bbff}code{color:#d3e3ff}
@media(max-width:650px){table{display:block;overflow:auto}main{margin-top:24px}}
</style><main><p class="intro">CINÉK8S · TESTS REPRODUCTIBLES</p>
HTML
        printf '<h1>%s</h1><p class="intro">Profil : <code>%s</code> · Debut : %s</p>\n' \
            "$outcome" "$(html_escape "$PROFILE")" "$(html_escape "$START_DATE")"
        printf '<div class="cards"><div class="card"><strong>%s</strong>verifications reussies</div><div class="card"><strong>%s</strong>echecs</div><div class="card"><strong>%s s</strong>duree</div></div>\n' "$PASSED" "$FAILED" "$elapsed"
        printf '<p><a href="commands.log">Commandes et sorties</a> · <a href="http.log">Reponses HTTP</a> · <a href="checks.tsv">Resultats TSV</a> · <a href="traffic.tsv">Trafic du rollout</a></p>\n'
        printf '<table><thead><tr><th>Etape</th><th>Resultat</th><th>Verification</th><th>Detail</th></tr></thead><tbody>\n'
        while IFS=$'\t' read -r stage verdict title detail; do
            printf '<tr><td>%s</td><td class="%s">%s</td><td>%s</td><td>%s</td></tr>\n' \
                "$(html_escape "$stage")" "$verdict" "$verdict" "$(html_escape "$title")" "$(html_escape "$detail")"
        done < "$RUN_DIR/checks.tsv"
        printf '</tbody></table><p class="intro">Ce rapport decrit cette execution. Les reponses de synthese sont dans reponses.md.</p></main></html>\n'
    } > "$RUN_DIR/rapport.html"
    printf '%s\nReussites : %s\nEchecs : %s\nDuree : %s s\n' "$outcome" "$PASSED" "$FAILED" "$elapsed" > "$RUN_DIR/resume.txt"
}

finish() {
    local status=$?
    trap - EXIT ERR INT TERM
    set +e
    if [ "$status" -ne 0 ] && [ "$FAILED" -eq 0 ]; then record ECHEC 'Execution interrompue' "Code de sortie $status."; fi
    stop_pid "$TRAFFIC_PID"
    stop_pid "$MOVIE_PID"
    stop_pid "$TICKET_PID"
    stop_pid "$TICKET_PF_PID"
    stop_pid "$INGRESS_PF_PID"
    if [ "$MOVIE_DOWN" -eq 1 ]; then
        kn scale deployment/movie --replicas=2 >> "$RUN_DIR/recovery.log" 2>&1
        kn --request-timeout=0 rollout status deployment/movie --timeout=900s >> "$RUN_DIR/recovery.log" 2>&1
    fi
    if [ "$DEBUG_CREATED" -eq 1 ]; then kn delete deployment ticket-debug --ignore-not-found >> "$RUN_DIR/recovery.log" 2>&1; fi
    if [ "$COMPOSE_STARTED" -eq 1 ]; then
        compose logs --no-color > "$RUN_DIR/compose.log" 2>&1
        compose down >> "$RUN_DIR/commands.log" 2>&1
    fi
    if [ "$CLUSTER_STARTED" -eq 1 ]; then
        kn get pods -o wide > "$RUN_DIR/final-pods.txt" 2>&1
        kn get events --sort-by=.lastTimestamp > "$RUN_DIR/events.txt" 2>&1
        kn logs deployment/movie --tail=100 > "$RUN_DIR/movie-kubernetes.log" 2>&1
        kn logs deployment/ticket --tail=100 > "$RUN_DIR/ticket-kubernetes.log" 2>&1
        k -n ingress-nginx logs deployment/ingress-nginx-controller --since=5m > "$RUN_DIR/ingress.log" 2>&1
    fi
    write_report "$status"
    printf '\nRapport : %s/rapport.html\nLogs    : %s\n' "$RUN_DIR" "$RUN_DIR"
    exit "$status"
}
