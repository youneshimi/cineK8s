# CinéK8s — démonstration pour le professeur

Le script `demo.sh` rejoue les parties 1 à 7 et les deux bonus du README, vérifie les résultats attendus et génère un rapport HTML. Les explications de l'examen restent dans `reponses.md`.

L'en-tête **Script BY Younes** s'affiche en rouge dans un terminal avec les couleurs activées. Il reste lisible sans couleurs dans les logs ou lorsque `NO_COLOR` est défini.

## Lancer la démonstration

Sur **Linux ou macOS**, depuis la racine du dépôt :

```bash
bash demo.sh --check
bash demo.sh
```

Prérequis : **JDK Java 21 ou plus** (`java` et `javac`), **Docker démarré avec Compose v2**, **Minikube**, **kubectl**, **curl** et **jq**, avec Bash 3.2 ou plus. Maven est lancé via les wrappers fournis dans le dépôt. Docker doit disposer d'au moins **2 CPU et 4 Go de mémoire disponibles pour le cluster**, en plus de la mémoire utilisée par les builds et les autres applications. La première exécution télécharge les dépendances et les images ; prévoir environ **15 à 30 minutes**, selon la connexion et la machine.

`--check` vérifie uniquement les prérequis. Le lancement complet vérifie ensuite les dépendances Java déclarées dans les deux `pom.xml` via Maven, qui récupère les fichiers absents du cache, compile les services et exécute leurs tests avant la partie Docker. Une erreur de résolution, de compilation ou de test arrête la démonstration.

Les ports utilisés par défaut sont **18080**, **18085** et **18086**. Si un port est déjà occupé :

```bash
bash demo.sh --port-base 19080
```

Les nouveaux ports seront alors 19080, 19085 et 19086. Il n'est pas nécessaire de modifier `/etc/hosts`, de lancer `minikube tunnel` ou d'utiliser `sudo` pour les ports. Les requêtes passent par un port-forward du **contrôleur Ingress**, avec l'en-tête `Host: cinema.local` ; elles vérifient donc réellement les règles de l'Ingress.

## Ce qui est présenté et vérifié

| Étape | Démonstration et contrôles |
|---|---|
| Prérequis | Outils, version Java, moteur Docker, ports disponibles |
| Partie 1 | Readiness dépendante de movie et arrêt gracieux ; renvoi vers les réponses de synthèse |
| Partie 2 | Compilation et tests Maven des deux services, lancement local, réservation à 36 €, erreurs 422/409/400, panne de movie, readiness DOWN, liveness UP et POST 503 |
| Partie 3 | Build des images et lancement du Compose fourni, environnement `compose`, réservation à 21 €, UID 10001 dans les deux conteneurs |
| Partie 4 | Profil Minikube dédié, chargement des images, validation des manifests, deux Pods prêts par service, EndpointSlices et appel interne par DNS, réservation à 24 € |
| Partie 5 | Ingress, quatre films, réservation à 90 €, deux hostnames movie, routage Prefix et Actuator inaccessible en 404 |
| Partie 6.1 | Movie à zéro réplica, ticket non prêt, aucun endpoint ticket prêt, Ingress 503, liveness UP, compteurs de redémarrage inchangés, puis restauration |
| Partie 6.2 | Reproduction des trois bugs du YAML initial, correction un par un et suppression de ticket-debug après réussite |
| Partie 6.3 | ConfigMap : `kubernetes` → `production`, ancienne valeur avant renouvellement des Pods, nouvelle valeur après, sans rebuild |
| Partie 7 | Quatre réservations, listes propres aux instances, remplacement automatique d'un Pod movie, perte des réservations après remplacement des Pods ticket |
| Bonus B1 | Contexte de sécurité sur tous les Pods movie, UID 10001, écriture `/test` refusée |
| Bonus B2 | 300 requêtes démarrées automatiquement avant un rollout ; vérification de 300 codes 200, des erreurs curl et des horaires de chevauchement |

La démonstration applique les manifests finaux : les réglages des bonus sont donc présents dès la partie 4, puis contrôlés dans la section bonus. Pour illustrer les listes en mémoire, une réservation supplémentaire est ajoutée si nécessaire afin d'avoir un total impair entre les deux instances et de rendre la différence observable.

L'observation des deux instances utilise jusqu'à 30 appels : le test n'exige pas une alternance stricte à chaque requête. Les images construites sont affichées avec leur utilisateur et leur taille ; leurs métadonnées sont conservées dans `docker-images.json`.

Avant de créer l'Ingress, le script attend aussi une validation `--dry-run=server` réussie. Cela vérifie le webhook d'admission, qui peut refuser les connexions brièvement même après que le Pod du contrôleur est prêt. Seules ses erreurs de connexion sont réessayées, pendant au maximum 180 secondes ; un manifest invalide fait échouer la démonstration.

## Rapport et preuves

Chaque exécution crée son propre dossier :

```text
reports/AAAAMMJJ-HHMMSS-PID/
├── rapport.html             Résultats organisés par étape
├── resume.txt               Succès/échec et nombre de vérifications
├── checks.tsv               Résultats structurés
├── commands.log             Commandes et sorties
├── http.log                 Codes et corps des réponses HTTP
├── traffic.tsv              Les 300 requêtes, avec horaires et codes curl
├── rolling-times.txt        Horaires du début et de la fin du rollout
├── tests-movie-service/     Rapports XML des tests Maven
├── tests-ticket-service/
└── *.log / *.json / *.txt    Logs et états de diagnostic
```

Ouvrir **`rapport.html`** dans un navigateur. Les liens du rapport sont relatifs : conserver le dossier entier pour consulter les preuves. Les rapports générés sont exclus de Git.

Le script s'arrête à la première vérification inattendue et retourne **1**. Un résultat attendu comme HTTP 503 pendant une panne ou l'échec de `touch /test` compte comme une réussite uniquement si la vérification correspondante passe. Le code **0** indique que toutes les vérifications exécutées ont réussi ; **2** indique une option invalide, **130** une interruption clavier.

## Environnement de démonstration et fin d'exécution

Le script crée ou réutilise le profil **`cinek8s-demo`**, avec le namespace **`cinema-exam`**. Il remplace les Pods et leurs données en mémoire **dans ce profil** pour les scénarios de panne et de perte de données. Ce profil doit être réservé à la démonstration. Un suffixe est possible :

```bash
bash demo.sh --profile cinek8s-demo-prof
```

Chaque commande `kubectl` vise explicitement ce profil ; le contexte habituel est conservé lors du démarrage de Minikube. Les fichiers rendus et `reponses.md` ne sont pas modifiés par le script. Le Compose est dérivé du fichier fourni, avec uniquement les ports publiés adaptés. Les variantes volontairement cassées de ticket-debug restent dans le dossier de rapport.

À la fin, les processus Java locaux, les port-forwards et le projet Compose de démonstration sont arrêtés. Le cluster reste disponible pour inspection. Si le script échoue pendant la panne à zéro réplica, il tente de restaurer movie à deux réplicas ; les diagnostics et le résultat de cette restauration restent dans le rapport.

Pour inspecter le cluster et rouvrir l'accès HTTP :

```bash
kubectl --context cinek8s-demo -n cinema-exam get pods
kubectl --context cinek8s-demo -n ingress-nginx port-forward --address 127.0.0.1 svc/ingress-nginx-controller 18080:80
```

Dans un autre terminal :

```bash
curl --noproxy '*' -H 'Host: cinema.local' http://127.0.0.1:18080/api/movies
```

Pour supprimer le cluster de démonstration après inspection :

```bash
minikube delete -p cinek8s-demo
```

## Vérifier le script sans déployer

```bash
bash scripts/test-demo.sh
```

Ces tests vérifient les options refusées, les codes d'échec, le traitement d'un HTTP 503 attendu et d'un timeout, l'échappement HTML et l'arrêt des processus créés par le script. Ils ne remplacent pas l'exécution complète avec Docker et Minikube.

## Validation Linux avant le commit, depuis Windows

Le fichier `compose.validation.yaml` permet de tester les fichiers de travail **avant de les commiter**. Il lance un Ubuntu temporaire avec Java 21, Bash, jq, ShellCheck, Minikube et kubectl, accompagné d'un conteneur Docker interne. Ils partagent leur réseau pour accéder aux ports locaux des services. Le script y construit les images, lance Compose et crée son cluster. Le dépôt est monté en lecture seule et copié dans cet environnement ; les rapports restent dans `reports/linux/` sur le PC.

Depuis PowerShell, à la racine du dépôt, avec Docker Desktop démarré :

```powershell
# Liberer la memoire du cluster habituel, en conservant ses donnees.
minikube stop -p minikube
New-Item -ItemType Directory -Force reports/linux | Out-Null
docker compose -p cinek8s-validation -f compose.validation.yaml up --build --abort-on-container-exit --exit-code-from validation
$LASTEXITCODE
```

Le conteneur du moteur Docker utilise le mode `privileged` pour faire tourner Docker et Kubernetes à l'intérieur. Le conteneur Ubuntu exécute Minikube avec un utilisateur non root. Aucun socket Docker du PC n'est monté et aucun port du moteur Docker n'est publié sur le PC. Prévoir au moins 6 Go alloués à Docker Desktop pour cette vérification et éviter de laisser tourner un autre cluster en parallèle.

La commande doit terminer avec le code **0**. Vérifier aussi le rapport de l'exécution complète dans `reports/linux/AAAAMMJJ-HHMMSS-PID/rapport.html`, avec les parties 1 à 7 et les bonus. Le rapport généré par `--check` contient seulement les prérequis : il ne valide pas le déploiement. `exit-code.txt` et `scripts-sha256.txt` complètent les preuves. Les logs du moteur interne sont accessibles avec `docker compose -p cinek8s-validation -f compose.validation.yaml logs docker`.

Après consultation, nettoyer le conteneur de validation et ses volumes temporaires :

```powershell
docker compose -p cinek8s-validation -f compose.validation.yaml down --volumes
```

Les rapports sur le PC sont conservés. Ce test Linux ne constitue pas un test sur macOS ; le professeur peut lancer directement `bash demo.sh` sur sa machine avec les prérequis indiqués plus haut.

Les volumes `validation-home` et `validation-docker` conservent les caches et le profil entre deux lancements, tant que `down --volumes` n'est pas exécuté. Cette commande permet aussi de refaire une validation complète depuis un environnement neuf.

## Résultat de la validation avant commit

Le **9 octobre 2026**, la démonstration complète a réussi dans l'environnement Ubuntu 22.04 amd64 de validation, avec Java 21, Docker et Minikube :

- **123 vérifications réussies, aucun échec**, parties 1 à 7 et bonus B1/B2 inclus.
- **9 tests Maven exécutés** : 4 pour movie et 5 pour ticket, sans échec ni test ignoré.
- **300 réponses HTTP 200 sans erreur curl**, avec un trafic démarré avant le rolling update et maintenu jusqu'après sa fin.
- **4 Pods prêts à la fin**, avec aucun redémarrage des conteneurs dans l'état final.
- Code de sortie **0**, durée **11 min 12 s**.

Les preuves de cette exécution sont dans `reports/linux/20261009-004917-44/`. Les empreintes SHA-256 identifient la version des trois scripts exécutés. Après cette validation, l'en-tête personnalisé **Script BY Younes** a été ajouté à l'affichage. Les rapports sont exclus de Git ; chaque nouvelle exécution produit ses propres preuves. Cette validation porte sur Ubuntu amd64 ; aucune exécution macOS n'a été réalisée.

## Validation complète sur Linux depuis GitHub

Le workflow **Demonstration complete CineK8s** peut être lancé manuellement depuis **Actions → Demonstration complete CineK8s → Run workflow**, une fois les fichiers poussés sur la branche `master`.

Il utilise un runner Ubuntu, installe Java 21 et les outils nécessaires, vérifie le script avec ShellCheck, lance ses tests, puis exécute la démonstration entière. L'artefact **`rapport-demonstration-cinek8s`** conserve les rapports et les logs, y compris en cas d'échec. Ce workflow propose une vérification supplémentaire : il n'a pas encore été exécuté sur GitHub. La validation avant commit décrite ci-dessus a été réalisée localement dans le conteneur Ubuntu.
