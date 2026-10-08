# Examen CinéK8s

## Partie 1 — Comprendre le code

### Q1.1 — URL de movie-service

`MovieClient` utilise la propriété **`movie.url`**, lue avec `@Value("${movie.url}")`, pour connaître l'URL de movie-service.

On peut remplacer sa valeur avec la variable d'environnement **`MOVIE_URL`**, sans changer le code Java. Par exemple, dans Kubernetes : `MOVIE_URL=http://movie:8080`.

### Q1.2 — Codes HTTP renvoyés par ticket-service

Pour un `POST /api/tickets` avec un nombre de places valide :

| Cas | Code HTTP de ticket-service | Explication |
|---|---|---|
| (a) Le film demandé n'existe pas | **422 — Unprocessable Entity** | Le client retourne un `Optional.empty()` et le contrôleur renvoie `UNPROCESSABLE_ENTITY`. |
| (b) Il reste moins de places que demandé | **409 — Conflict** | Le contrôleur compare les places disponibles aux places demandées et renvoie `CONFLICT`. |
| (c) movie-service ne répond pas du tout | **503 — Service Unavailable** | Le contrôleur intercepte la `ResourceAccessException` et renvoie `SERVICE_UNAVAILABLE`. |

Pour le film inconnu, movie-service répond `404`, mais ticket-service transforme ce cas en `422` pour son propre client.

### Q1.3 — Readiness dépendante de movie-service

Dans `ticket-service/src/main/resources/application.yaml`, la ligne complétée est :

```yaml
          include: readinessState,movie
```

Le nom `movie` vient de `@Component("movie")` dans `MovieHealthIndicator`.

Cette dépendance appartient à la **readiness** : si movie-service tombe, les Pods ticket ne reçoivent plus de trafic du Service, mais leurs conteneurs continuent à fonctionner. Elle ne doit jamais être dans la **liveness**, car cela ferait redémarrer ticket-service sans réparer movie-service, avec un risque de redémarrages en cascade.

### Q1.4 — Probes et arrêt gracieux

| Endpoint | Probe(s) Kubernetes dans cet examen | Conséquence d'un échec |
|---|---|---|
| `/actuator/health/liveness` | **`startupProbe`** et **`livenessProbe`** | Après le nombre d'échecs consécutifs défini par `failureThreshold`, le kubelet arrête le conteneur, qui est redémarré dans ce Deployment. |
| `/actuator/health/readiness` | **`readinessProbe`** | Après le seuil d'échecs consécutifs, le Pod devient **NotReady** et ne reçoit plus de trafic du Service ; cet échec ne provoque pas de redémarrage. |

Tant que la startupProbe n'a pas réussi, Kubernetes n'exécute pas les probes de liveness et de readiness.

Lors d'un rolling update, **`server.shutdown: graceful`** permet au serveur de terminer les requêtes en cours dans le délai prévu, tout en cessant d'accepter de nouvelles requêtes avant son arrêt.

## Partie 2 — Tester en local, sans Kubernetes

### 2.1 — Compilation et fonctionnement des deux services

Les deux projets ont été compilés avec `.\mvnw.cmd -B package`, dans leurs dossiers respectifs. Les rapports de tests donnent :

| Service | Tests exécutés | Échecs | Erreurs | Tests ignorés |
|---|---:|---:|---:|---:|
| movie-service | 4 | 0 | 0 | 0 |
| ticket-service | 5 | 0 | 0 | 0 |

Les fichiers `movie-service-1.0.0.jar` et `ticket-service-1.0.0.jar` ont été produits.

Les fichiers fournis définissent les ports 8085 et 8086. Pour utiliser les ports du README, les services ont été lancés avec `SERVER_PORT=8080` pour movie et `SERVER_PORT=8082` pour ticket ; ticket utilise `MOVIE_URL=http://localhost:8080`.

Réponse observée pour `GET http://localhost:8080/api/movies/whoami` (HTTP 200) :

```json
{"environment":"local","hostname":"Younes-Legion"}
```

La réservation a été créée avec ces commandes PowerShell :

```powershell
$body = '{"movieId":2,"seats":3}'
(Invoke-WebRequest -UseBasicParsing -Method Post -Uri http://localhost:8082/api/tickets -ContentType "application/json" -Body $body).Content
```

La réservation a ensuite été retrouvée avec `GET http://localhost:8082/api/tickets` (HTTP 200), qui a renvoyé :

```json
[
  {
    "id": 1,
    "movieId": 2,
    "movieTitle": "Le Seigneur des Pods",
    "seats": 3,
    "total": 36.00,
    "createdAt": "2026-10-08T09:58:31.286994200Z"
  }
]
```

Commande de vérification de la readiness :

```powershell
Invoke-RestMethod http://localhost:8082/actuator/health/readiness | ConvertTo-Json -Depth 5
```

Réponse observée (HTTP 200) :

```json
{
  "status": "UP",
  "components": {
    "movie": {
      "status": "UP"
    },
    "readinessState": {
      "status": "UP"
    }
  }
}
```

### 2.2 — Arrêt de movie-service

Après l'arrêt de movie-service, les commandes suivantes ont donné ces résultats.

Readiness de ticket-service :

```powershell
curl.exe -s http://localhost:8082/actuator/health/readiness
```

```json
{
  "status": "DOWN",
  "components": {
    "movie": {
      "status": "DOWN",
      "details": {
        "error": "I/O error on GET request for \"http://localhost:8080/actuator/health/liveness\": null"
      }
    },
    "readinessState": {
      "status": "UP"
    }
  }
}
```

La readiness répond en HTTP **503** : l'indicateur `movie` est `DOWN`, même si `readinessState` reste `UP`.

Liveness de ticket-service :

```powershell
curl.exe -s http://localhost:8082/actuator/health/liveness
```

```json
{"status":"UP"}
```

La liveness répond toujours en HTTP **200**.

Tentative de réservation pendant la panne :

```powershell
'{"movieId":2,"seats":3}' | curl.exe -s -o NUL -w "%{http_code}\n" -H "Content-Type: application/json" --data-binary "@-" http://localhost:8082/api/tickets
```

Sortie :

```text
503
```

### Q2.1 — Utilisation de SERVER_PORT

`SERVER_PORT=8082` permet de choisir le port au lancement, sans modifier le fichier `application.yaml`. Cela évite le conflit avec movie-service sur le port 8080 et permet de réutiliser le même JAR dans plusieurs environnements.

Spring Boot utilise sa configuration externe : la variable d'environnement `SERVER_PORT` correspond à `server.port` et prend le dessus sur la valeur du YAML. Cette correspondance suit les règles de relaxed binding.

### Q2.2 — Liveness UP et readiness DOWN

La liveness reste `UP` parce que ticket-service fonctionne encore : la panne concerne son service distant movie. Sa readiness passe à `DOWN` parce qu'il ne peut plus valider de nouvelles réservations.

C'est le comportement voulu : dans Kubernetes, cette panne retirera le Pod du trafic du Service, sans déclencher un redémarrage de ticket-service qui ne réparerait pas movie-service.

## Partie 3 — Conteneuriser

### 3.1 — Construction des images

Les deux Dockerfiles utilisent Maven avec un JDK 21 pour compiler, puis un JRE 21 Alpine pour exécuter le JAR. Les tests ont déjà été exécutés en partie 2 ; le build Docker utilise `-DskipTests`.

Le port est fixé à 8080 dans les images avec `ENV SERVER_PORT=8080`, pour utiliser les ports du README avec les fichiers de configuration fournis.

Commandes de construction :

```powershell
docker build -t movie-service:1.0.0 ./movie-service
docker build -t ticket-service:1.0.0 ./ticket-service
```

Les deux images ont été construites :

| Image | Taille affichée par Docker |
|---|---:|
| movie-service:1.0.0 | 331 MB |
| ticket-service:1.0.0 | 331 MB |

La somme des couches indiquées par `docker image history` est d'environ 236 MB par image. Le stockage containerd conserve les couches compressées et décompressées, ce qui explique la taille affichée plus élevée : [documentation Docker](https://docs.docker.com/engine/storage/containerd/#disk-space-usage).

Vérification de l'utilisateur de chaque image :

```powershell
docker run --rm --entrypoint id movie-service:1.0.0
```

```text
uid=10001(spring) gid=101(spring) groups=101(spring)
```

```powershell
docker run --rm --entrypoint id ticket-service:1.0.0
```

```text
uid=10001(spring) gid=101(spring) groups=101(spring)
```

### 3.2 — Test avec Docker Compose

Commandes exécutées :

```powershell
docker compose up -d --build
docker compose ps
```

État observé :

```text
NAME               IMAGE                  COMMAND                  SERVICE   CREATED          STATUS                    PORTS
cinek8s-movie-1    movie-service:1.0.0    "java -XX:MaxRAMPerc…"   movie     10 seconds ago   Up 10 seconds (healthy)   0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp
cinek8s-ticket-1   ticket-service:1.0.0   "java -XX:MaxRAMPerc…"   ticket    10 seconds ago   Up 5 seconds              0.0.0.0:8082->8080/tcp, [::]:8082->8080/tcp
```

Movie reçoit `MOVIE_ENVIRONMENT=compose`. Ticket reçoit `MOVIE_URL=http://movie:8080` et démarre après le passage du healthcheck de movie à `healthy`.

```powershell
curl.exe -s http://localhost:8080/api/movies/whoami
```

```json
{"environment":"compose","hostname":"b5b4727199e5"}
```

Création d'une réservation :

```powershell
$body = '{"movieId":1,"seats":2}'
(Invoke-WebRequest -UseBasicParsing -Method Post -Uri http://localhost:8082/api/tickets -ContentType "application/json" -Body $body).Content
```

Réponse reçue, puis retrouvée avec `GET /api/tickets` :

```json
{
  "id": 1,
  "movieId": 1,
  "movieTitle": "Pod Fiction",
  "seats": 2,
  "total": 21.00,
  "createdAt": "2026-10-08T10:49:25.175059063Z"
}
```

La readiness de ticket répond en HTTP 200 avec `status: UP`, `movie: UP` et `readinessState: UP`.

### Q3.1 — Cache des couches Docker

Copier `pom.xml` avant `src/` permet de mettre en cache le téléchargement des dépendances Maven. Si seule une ligne de Java change, la copie des sources et la compilation sont refaites, mais la couche de téléchargement des dépendances peut être réutilisée puisque le `pom.xml` n'a pas changé.

### Q3.2 — Mémoire de la JVM

`-XX:MaxRAMPercentage=75` adapte la taille maximale du heap à la mémoire disponible pour la JVM, en tenant compte de la limite du conteneur. Cela laisse une marge pour les autres besoins de mémoire de la JVM, comme le metaspace et les piles des threads.

Avec `-Xmx512m`, la taille maximale du heap est fixée à 512 MiB, même si la limite du conteneur change : pour un conteneur limité à 512 MiB, les besoins de mémoire hors heap peuvent alors provoquer un dépassement de la limite.

### Q3.3 — Démarrage de ticket avant movie dans Kubernetes

Les Pods ticket peuvent démarrer avant les Pods movie. Leur JVM peut être vivante, donc la startupProbe peut réussir et la liveness rester `UP`, mais la readiness sera `DOWN` tant que movie sera injoignable.

Les Pods ticket restent alors hors du trafic du Service. Quand movie devient disponible, les prochaines probes de readiness réussissent et Kubernetes leur envoie du trafic, sans devoir les redémarrer pour cette panne de dépendance.

## Partie 4 — Déployer sur Minikube

### 4.0 — Préparation du cluster et chargement des images

Le cluster de l'examen utilise Minikube avec le pilote Docker, 2 CPU et 4 Gio de RAM :

```powershell
minikube start --driver=docker --cpus=2 --memory=4096
minikube status
```

État vérifié après le démarrage :

```text
minikube
type: Control Plane
host: Running
kubelet: Running
apiserver: Running
kubeconfig: Configured
```

Le nœud était encore `NotReady` juste après la création, puis il est devenu `Ready` :

```text
NAME       STATUS   ROLES           AGE     VERSION
minikube   Ready    control-plane   3m18s   v1.37.0
```

Les images construites en partie 3 ont été chargées avec l'option C du README :

```powershell
minikube image load movie-service:1.0.0
minikube image load ticket-service:1.0.0
minikube image ls | Select-String "movie-service|ticket-service"
```

Sortie observée :

```text
docker.io/library/ticket-service:1.0.0
docker.io/library/movie-service:1.0.0
```

### 4.1 — Namespace et ConfigMaps

Les manifests `00-namespace.yaml` et `10-config.yaml` ont été appliqués dans le cluster Minikube :

```powershell
kubectl --context minikube apply -f k8s/00-namespace.yaml
kubectl --context minikube apply -f k8s/10-config.yaml
kubectl config set-context minikube --namespace=cinema-exam
kubectl --context minikube get configmaps -n cinema-exam
```

Sortie observée pour les ConfigMaps :

```text
NAME               DATA   AGE
kube-root-ca.crt   1      10s
movie-config       1      7s
ticket-config      1      7s
```

`kube-root-ca.crt` est ajouté automatiquement par Kubernetes. Les deux ConfigMaps de l'application ont les valeurs suivantes, vérifiées dans le cluster :

| ConfigMap | Variable d'environnement | Valeur |
|---|---|---|
| movie-config | MOVIE_ENVIRONMENT | kubernetes |
| ticket-config | MOVIE_URL | http://movie:8080 |

Le namespace `cinema-exam` est actif et sélectionné dans le contexte `minikube`.

### 4.2 — Déploiement de movie

Le fichier `20-movie.yaml` contient le Deployment et le Service de movie. Il utilise deux réplicas de l'image `movie-service:1.0.0`, avec `IfNotPresent` pour utiliser l'image déjà chargée dans Minikube. La configuration vient de `movie-config`.

Chaque conteneur demande 100m de CPU et 256 MiB de mémoire, avec une limite de mémoire de 512 MiB. Les trois probes utilisent Actuator : startup et liveness sur `/actuator/health/liveness`, readiness sur `/actuator/health/readiness`.

Commandes exécutées :

```powershell
kubectl --context minikube apply -f k8s/20-movie.yaml
kubectl --context minikube rollout status deployment/movie -n cinema-exam --timeout=180s
kubectl --context minikube get pods -n cinema-exam -l app=movie
kubectl --context minikube get service movie -n cinema-exam
```

Sorties observées :

```text
deployment "movie" successfully rolled out

NAME                     READY   STATUS    RESTARTS   AGE
movie-59684459f4-tm79l   1/1     Running   0          60s
movie-59684459f4-xntzw   1/1     Running   0          60s

NAME    TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
movie   ClusterIP   10.110.158.150   <none>        8080/TCP   65s
```

Le Service sélectionne bien les deux Pods grâce au label `app: movie`. Vérification des EndpointSlices : les adresses `10.244.0.4` et `10.244.0.3` sont toutes les deux prêtes, sur le port 8080.

### 4.3 — Déploiement de ticket

Le fichier `30-ticket.yaml` contient le Deployment et le Service de ticket. Il utilise deux réplicas de l'image `ticket-service:1.0.0`, avec `IfNotPresent` et la ConfigMap `ticket-config`. Le Service sélectionne les Pods avec le label `app: ticket` et envoie le trafic du port 8080 vers le port nommé `http` du conteneur.

Les ressources, la startupProbe et la livenessProbe sont identiques à celles de movie. La readinessProbe utilise `/actuator/health/readiness`, toutes les 5 secondes, avec `timeoutSeconds: 3` : elle doit laisser le temps à ticket de vérifier movie par HTTP.

Commandes exécutées :

```powershell
kubectl --context minikube apply -f k8s/30-ticket.yaml
kubectl --context minikube rollout status deployment/ticket -n cinema-exam --timeout=180s
kubectl --context minikube get pods -n cinema-exam
kubectl --context minikube get endpoints movie ticket -n cinema-exam
```

Le rollout de ticket s'est terminé avec succès.

### 4.4 — Vérifications du déploiement

Sortie observée pour les quatre Pods :

```text
NAME                      READY   STATUS    RESTARTS   AGE
movie-59684459f4-tm79l    1/1     Running   0          5m7s
movie-59684459f4-xntzw    1/1     Running   0          5m7s
ticket-66d95c98b6-djfpb   1/1     Running   0          11s
ticket-66d95c98b6-lrtwv   1/1     Running   0          11s
```

Sortie observée pour les adresses derrière les Services :

```text
NAME     ENDPOINTS                         AGE
movie    10.244.0.3:8080,10.244.0.4:8080   5m10s
ticket   10.244.0.5:8080,10.244.0.6:8080   14s
```

Kubernetes signale que l'API Endpoints est dépréciée depuis la version 1.33. La commande du README fonctionne encore ; une vérification des EndpointSlices confirme les deux adresses pour chacun des Services.

La validation globale et l'application du dossier `k8s/` ont réussi :

```powershell
kubectl --context minikube apply --dry-run=client -f k8s/
kubectl --context minikube apply -f k8s/
```

Les sept ressources sont signalées `unchanged`, car elles avaient déjà été appliquées étape par étape.

Appel de movie depuis un Pod ticket, en utilisant le nom DNS du Service :

```powershell
kubectl --context minikube exec -n cinema-exam deploy/ticket -- wget -qO- http://movie:8080/api/movies/whoami
```

```json
{"hostname":"movie-59684459f4-xntzw","environment":"kubernetes"}
```

Vérification de la readiness de ticket depuis ce Pod :

```powershell
kubectl --context minikube exec -n cinema-exam deploy/ticket -- wget -qO- http://localhost:8080/actuator/health/readiness
```

```json
{"status":"UP","components":{"movie":{"status":"UP"},"readinessState":{"status":"UP"}}}
```

L'appel inter-services fonctionne et ticket confirme que movie est disponible.

Pour tester une réservation depuis Windows, j'ai ouvert un port-forward dans un premier terminal :

```powershell
kubectl --context minikube port-forward -n cinema-exam svc/ticket 8082:8080
```

Dans un deuxième terminal PowerShell :

```powershell
$body = '{"movieId":2,"seats":2}'
(Invoke-WebRequest -UseBasicParsing -Method Post -Uri http://localhost:8082/api/tickets -ContentType "application/json" -Body $body).Content
```

Réservation obtenue :

```json
{"id":1,"movieId":2,"movieTitle":"Le Seigneur des Pods","seats":2,"total":24.00,"createdAt":"2026-10-08T11:31:11.391778074Z"}
```

Le total correspond bien à deux places à 12,00 € chacune.

### Q4.1 — Ordre des fichiers

`kubectl apply -f k8s/` parcourt les fichiers du dossier dans l'ordre lexicographique de leurs noms. Ici, les préfixes donnent l'ordre `00-namespace.yaml`, `10-config.yaml`, `20-movie.yaml`, puis `30-ticket.yaml`.

Le namespace est donc créé avant les ressources qu'il contient, et les ConfigMaps avant les Deployments qui les utilisent. Cet ordre ne garantit pas que movie soit déjà prêt au démarrage de ticket : il faut les probes pour gérer cela.

Cet ordre est confirmé par le [code de parcours des fichiers de kubectl](https://github.com/kubernetes/cli-runtime/blob/master/pkg/resource/visitor.go) et la [documentation de filepath.Walk](https://pkg.go.dev/path/filepath#Walk).

### Q4.2 — Pods à 0/1 au démarrage

La startupProbe attend que Spring Boot ait démarré. Tant qu'elle n'a pas réussi, Kubernetes suspend la livenessProbe et la readinessProbe : le conteneur ne peut donc pas encore être déclaré prêt. Après son succès, la readinessProbe doit aussi réussir pour passer à `1/1` et recevoir du trafic.

Un `0/1` temporaire au démarrage est normal. La startupProbe laisse environ 60 secondes à l'application, avec 30 échecs possibles et un intervalle de 2 secondes. La durée réelle varie : dans mon essai, les Pods ticket étaient déjà `1/1` à 11 secondes. Voir la [documentation Kubernetes sur les probes](https://kubernetes.io/docs/concepts/workloads/pods/probes/).

### Q4.3 — Images avec Always

Avec `imagePullPolicy: Always`, le runtime contacterait le registre à chaque démarrage du conteneur pour résoudre le tag de l'image. Nos images ont été construites localement et chargées dans Minikube, sans être publiées sur Docker Hub sous ces noms. Le démarrage échouerait donc avec `ErrImagePull`, puis `ImagePullBackOff`, même si les images sont présentes sur le nœud.

`IfNotPresent` permet d'utiliser directement les images locales. `Always` ne signifie pas forcément retélécharger toutes les couches : si la résolution auprès du registre réussit, les couches déjà en cache peuvent être réutilisées. Voir la [documentation Kubernetes sur les images](https://kubernetes.io/docs/concepts/containers/images/#image-pull-policy).

## Partie 5 — Exposer avec un Ingress

### 5.1 — Activation du contrôleur Ingress

Commandes exécutées :

```powershell
minikube addons enable ingress
kubectl --context minikube wait -n ingress-nginx --for=condition=Ready pod -l app.kubernetes.io/component=controller --timeout=180s
kubectl --context minikube get pods -n ingress-nginx
kubectl --context minikube get ingressclass
```

Le module ingress a été activé. Le contrôleur utilise l'image `registry.k8s.io/ingress-nginx/controller:v1.15.1`.

Sorties observées :

```text
pod/ingress-nginx-controller-d7cd8c989-bdz8c condition met

NAME                                       READY   STATUS      RESTARTS   AGE
ingress-nginx-admission-create-mjxr9       0/1     Completed   0          81s
ingress-nginx-admission-patch-pdv8m        0/1     Completed   0          81s
ingress-nginx-controller-d7cd8c989-bdz8c   1/1     Running     0          81s

NAME              CONTROLLER             PARAMETERS   AGE
nginx (default)   k8s.io/ingress-nginx   <none>       86s
```

Les deux Pods d'admission ont terminé leur travail. Le contrôleur est prêt et la classe à utiliser dans l'Ingress est `nginx`.

#### Accès local sous Windows

Le port 80 en IPv4 est déjà utilisé par Docker Desktop. J'ai donc utilisé l'adresse locale IPv6 `::1`, dont le port 80 était libre, pour conserver l'URL `http://cinema.local`.

Dans le fichier `C:\Windows\System32\drivers\etc\hosts`, ouvert avec les droits administrateur, j'ai ajouté :

```text
::1 cinema.local
```

Un terminal reste ouvert avec cette redirection vers le contrôleur Ingress :

```powershell
kubectl --context minikube port-forward -n ingress-nginx svc/ingress-nginx-controller --address ::1 80:80
```

```text
Forwarding from [::1]:80 -> 80
Handling connection for 80
```

L'option `--address` permet de choisir l'adresse d'écoute locale du port-forward. Voir la [documentation kubectl](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_port-forward/).

Avant de créer les règles de routage, j'ai testé dans un deuxième terminal :

```powershell
curl.exe -6 --noproxy "*" --max-time 10 -sS -o NUL -w "%{http_code}\n" http://cinema.local/
```

```text
404
```

Ce résultat confirme que le contrôleur est accessible. À ce stade, aucune règle Ingress n'est encore créée pour l'application.

### 5.2 — Création des règles Ingress

Le fichier `40-ingress.yaml` utilise l'API `networking.k8s.io/v1`, la classe `nginx` et l'hôte `cinema.local`. Les deux chemins utilisent `pathType: Prefix` et pointent vers le port nommé `http` des Services.

Commandes exécutées :

```powershell
kubectl --context minikube apply -f k8s/40-ingress.yaml
kubectl --context minikube describe ingress cinema -n cinema-exam
```

Sortie observée :

```text
Name:             cinema
Labels:           <none>
Namespace:        cinema-exam
Address:          192.168.49.2
Ingress Class:    nginx
Default backend:  <default>
Rules:
  Host          Path  Backends
  ----          ----  --------
  cinema.local
                /api/movies    movie:http (10.244.0.4:8080,10.244.0.3:8080)
                /api/tickets   ticket:http (10.244.0.5:8080,10.244.0.6:8080)
Annotations:    <none>
Events:
  Type    Reason  Age                From                      Message
  ----    ------  ----               ----                      -------
  Normal  Sync    59s (x2 over 91s)  nginx-ingress-controller  Scheduled for sync
```

Les deux Services sont associés aux bonnes routes, avec deux Pods disponibles pour chacun. L'adresse affichée est celle du nœud Minikube ; depuis Windows, l'accès local passe par le port-forward configuré en 5.1.

Une vérification HTTP confirme que `/api/movies` et `/api/movies/1` répondent tous les deux en HTTP 200. Le deuxième appel retourne bien le film `Pod Fiction`, ce qui vérifie aussi le routage d'un sous-chemin.

### 5.3 — Tests via cinema.local

Le port-forward du contrôleur Ingress reste ouvert pendant les tests.

Liste des films :

```powershell
(curl.exe -6 --noproxy "*" -sS http://cinema.local/api/movies | ConvertFrom-Json) | Select-Object -ExpandProperty title
```

```text
Pod Fiction
Le Seigneur des Pods
Docker Wars
Rollback to the Future
```

Réservation de dix places pour le film 3 :

```powershell
$body = '{"movieId":3,"seats":10}'
(Invoke-WebRequest -UseBasicParsing -Method Post -Uri http://cinema.local/api/tickets -ContentType "application/json" -Body $body).Content
```

```json
{"id":2,"movieId":3,"movieTitle":"Docker Wars","seats":10,"total":90.00,"createdAt":"2026-10-08T11:50:25.075101329Z"}
```

Le total est correct : 10 places à 9,00 € donnent 90,00 €.

Six appels à whoami :

```powershell
1..6 | ForEach-Object {
    (curl.exe -6 --noproxy "*" -sS http://cinema.local/api/movies/whoami | ConvertFrom-Json).hostname
}
```

```text
movie-59684459f4-tm79l
movie-59684459f4-xntzw
movie-59684459f4-tm79l
movie-59684459f4-xntzw
movie-59684459f4-tm79l
movie-59684459f4-xntzw
```

Test d'Actuator via l'Ingress :

```powershell
curl.exe -6 --noproxy "*" -sS -o NUL -w "%{http_code}\n" http://cinema.local/actuator/health
```

```text
404
```

### Q5.1 — Répartition des appels

Deux Pods movie distincts ont répondu : `movie-59684459f4-tm79l` et `movie-59684459f4-xntzw`, avec trois réponses chacun dans cette boucle.

Le Service `movie` regroupe ces Pods grâce au sélecteur `app: movie` et constitue le backend déclaré dans l'Ingress. Lors d'un accès par son ClusterIP, le trafic du Service est réparti vers ses Pods prêts.

Pour les appels HTTP passant ici par l'Ingress, le contrôleur NGINX utilise par défaut les adresses des Pods derrière ce Service et répartit directement les requêtes entre elles. Ce fonctionnement est décrit dans la [documentation Ingress-NGINX](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#service-upstream).

### Q5.2 — Chemin Exact

Avec `pathType: Exact` sur `/api/movies`, seul ce chemin exact correspondrait à la règle. `/api/movies/1` ne correspondrait plus et, avec nos autres règles, recevrait un HTTP 404 du backend par défaut.

`Prefix` permet de router aussi les sous-chemins, comme `/api/movies/1` et `/api/movies/whoami`. Voir la [documentation Kubernetes sur les types de chemins](https://kubernetes.io/docs/concepts/services-networking/ingress/#path-types).

### Q5.3 — Actuator via l'Ingress

J'obtiens un HTTP 404 pour `/actuator/health`. L'Ingress ne déclare que les routes `/api/movies` et `/api/tickets`, donc ce chemin ne correspond à aucune règle.

C'est souhaitable ici : les informations de santé restent accessibles aux probes Kubernetes à l'intérieur du cluster, sans être exposées par l'URL de l'application. Le 404 de l'Ingress ne signifie pas que les services sont en panne : leurs Pods sont prêts et les appels aux API fonctionnent.
