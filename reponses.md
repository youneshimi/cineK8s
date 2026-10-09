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

Les ressources, la startupProbe et la livenessProbe sont identiques à celles de movie. La readinessProbe utilise `/actuator/health/readiness`, toutes les 5 secondes, avec `timeoutSeconds: 5` : elle doit laisser le temps à ticket de vérifier movie par HTTP, y compris sur une VM plus lente.

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

Un `0/1` temporaire au démarrage est normal. Dans mon premier essai, les Pods ticket étaient déjà `1/1` à 11 secondes, avec une startupProbe de 30 échecs possibles espacés de 2 secondes. Un essai ultérieur sur VM a montré que ce budget de 60 secondes pouvait provoquer des redémarrages avant la fin du démarrage. Les manifests actuels laissent donc environ 300 secondes à l'application, avec 60 échecs possibles espacés de 5 secondes et un délai de réponse de 5 secondes. Voir la [documentation Kubernetes sur les probes](https://kubernetes.io/docs/concepts/workloads/pods/probes/).

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

## Partie 6 — Casser pour comprendre

### 6.1 — Arrêt des réplicas de movie

#### Prédictions écrites avant l'arrêt de movie

| Point | Prédiction après environ 30 secondes avec movie à 0 réplica |
|---|---|
| (a) Pods ticket | Les deux Pods restent `Running`, mais passent à `0/1` READY. Leur compteur RESTARTS reste à `0`. |
| (b) Endpoints ticket | Aucune adresse prête : `kubectl get endpoints ticket` devrait afficher `<none>`. Les Pods ticket existent toujours, mais ne sont plus utilisables pour le trafic du Service. |
| (c) GET via l'Ingress | `GET http://cinema.local/api/tickets` devrait répondre en HTTP `503`, car le contrôleur Ingress n'a plus de Pod ticket prêt auquel envoyer la requête. |
| (d) Liveness ticket | La liveness devrait rester `UP`, car la JVM de ticket fonctionne et cette probe ne dépend pas de movie. |

La readiness de ticket inclut le composant `movie`. Après trois échecs consécutifs de la readinessProbe, les Pods deviennent non prêts. La liveness vérifie la santé de ticket et ne provoque donc pas de redémarrage pour cette panne de dépendance.

#### Observations pendant la panne

Commandes exécutées :

```powershell
kubectl --context minikube scale deployment/movie -n cinema-exam --replicas=0
Start-Sleep -Seconds 30
kubectl --context minikube get pods -n cinema-exam
kubectl --context minikube get endpoints ticket -n cinema-exam
curl.exe -6 --noproxy "*" --max-time 10 -sS -o NUL -w "%{http_code}\n" http://cinema.local/api/tickets
kubectl --context minikube describe pods -n cinema-exam -l app=ticket | Select-String "Readiness probe failed"
kubectl --context minikube exec -n cinema-exam deploy/ticket -- wget -qO- http://localhost:8080/actuator/health/liveness
```

Pods après l'arrêt de movie :

```text
NAME                      READY   STATUS    RESTARTS   AGE
ticket-66d95c98b6-djfpb   0/1     Running   0          28m
ticket-66d95c98b6-lrtwv   0/1     Running   0          28m
```

Adresses prêtes du Service ticket :

```text
NAME     ENDPOINTS   AGE
ticket               28m
```

La colonne ENDPOINTS est vide dans cette version de Kubernetes, plutôt que d'afficher littéralement `<none>`. Le résultat est bien celui attendu : aucune adresse prête. Une lecture des EndpointSlices confirme que les deux adresses `10.244.0.5` et `10.244.0.6` existent toujours, avec `ready: false`.

Code HTTP de `GET /api/tickets` via l'Ingress :

```text
503
```

Liveness de ticket :

```json
{"status":"UP"}
```

La première commande `describe` filtrée n'a affiché aucune ligne. Une vérification complémentaire des événements a ensuite montré l'échec de la readiness pour les deux Pods :

```powershell
kubectl --context minikube get events -n cinema-exam --field-selector type=Warning -o wide
```

Extrait des événements observés :

| Pod | Type / raison | Message |
|---|---|---|
| ticket-66d95c98b6-djfpb | Warning / Unhealthy | Readiness probe failed: HTTP probe failed with statuscode: 503 |
| ticket-66d95c98b6-lrtwv | Warning / Unhealthy | Readiness probe failed: HTTP probe failed with statuscode: 503 |

#### Rétablissement de movie

Commandes exécutées :

```powershell
kubectl --context minikube scale deployment/movie -n cinema-exam --replicas=2
kubectl --context minikube rollout status deployment/movie -n cinema-exam --timeout=180s
kubectl --context minikube wait pod -n cinema-exam -l app=ticket --for=condition=Ready --timeout=180s
kubectl --context minikube get pods -n cinema-exam
kubectl --context minikube get endpoints movie ticket -n cinema-exam
curl.exe -6 --noproxy "*" --max-time 10 -sS -o NUL -w "%{http_code}\n" http://cinema.local/api/tickets
```

Sorties observées :

```text
deployment "movie" successfully rolled out
pod/ticket-66d95c98b6-djfpb condition met
pod/ticket-66d95c98b6-lrtwv condition met

NAME                      READY   STATUS    RESTARTS   AGE
movie-59684459f4-76zpj    1/1     Running   0          14s
movie-59684459f4-thql2    1/1     Running   0          14s
ticket-66d95c98b6-djfpb   1/1     Running   0          31m
ticket-66d95c98b6-lrtwv   1/1     Running   0          31m

NAME     ENDPOINTS                           AGE
movie    10.244.0.10:8080,10.244.0.11:8080   36m
ticket   10.244.0.5:8080,10.244.0.6:8080     31m
```

L'appel à `/api/tickets` via l'Ingress répond de nouveau en HTTP 200. Deux nouveaux Pods movie ont été créés. Les Pods ticket ont gardé leurs noms, leurs adresses et leur compteur RESTARTS à zéro : ils sont redevenus prêts automatiquement quand movie a été disponible.

### Q6.1 — De l'arrêt de movie au HTTP 503

1. Le passage de movie à zéro réplica supprime ses Pods. Le Service movie existe encore, mais il n'a plus de Pod disponible pour répondre à l'appel de ticket.
2. Le composant de santé `movie` de ticket passe à `DOWN`. La readiness répond en HTTP 503 et, après les échecs consécutifs de la probe, les Pods ticket passent à `0/1`.
3. Kubernetes marque les adresses des Pods ticket comme non prêtes dans les EndpointSlices. Il n'y a donc plus de backend ticket prêt à recevoir le trafic.
4. Le contrôleur Ingress ne peut plus envoyer `GET /api/tickets` à un Pod ticket prêt et renvoie HTTP 503 au client.

RESTARTS reste à `0` parce qu'un échec de readiness retire le Pod du trafic sans redémarrer son conteneur. La liveness reste `UP`, puisque ticket fonctionne encore : la panne concerne sa dépendance movie.

### 6.2 — Dépannage de ticket-debug

Le fichier fourni a été appliqué une première fois avant toute correction :

```powershell
kubectl --context minikube apply -f broken/ticket-debug.yaml
Start-Sleep -Seconds 15
kubectl --context minikube get pods -n cinema-exam -l app=ticket-debug
kubectl --context minikube describe pods -n cinema-exam -l app=ticket-debug
```

Premier statut observé :

```text
NAME                            READY   STATUS             RESTARTS   AGE
ticket-debug-6bc9655bd5-zmngr   0/1     ImagePullBackOff   0          22s
```

Le conteneur est en attente et les événements montrent `ErrImagePull`, puis `ImagePullBackOff`. La tentative de téléchargement de `docker.io/library/ticket-service:1.0.0` échoue avec le message :

```text
pull access denied, repository does not exist or may require authorization: server message: insufficient_scope: authorization failed
```

La politique `Always` oblige le runtime à contacter le registre, alors que l'image de l'examen a été construite localement et chargée dans Minikube. La première correction du YAML remplace uniquement `Always` par `IfNotPresent`.

| # | Statut observé | Commande de diagnostic | Cause exacte | Correction apportée |
|---|---|---|---|---|
| 1 | `ImagePullBackOff` ; `ErrImagePull` dans les événements | `kubectl --context minikube describe pods -n cinema-exam -l app=ticket-debug` | `imagePullPolicy: Always` tente de télécharger l'image depuis Docker Hub, qui refuse cette référence. | Remplacer `Always` par `IfNotPresent` pour utiliser l'image présente sur le nœud. |
| 2 | `CreateContainerConfigError` | `kubectl --context minikube describe pods -n cinema-exam -l app=ticket-debug`, puis lecture des événements du nouveau Pod et des ConfigMaps | La référence `ticket-configmap` ne correspond à aucune ConfigMap du namespace ; celle créée en partie 4 s'appelle `ticket-config`. | Remplacer le nom dans `configMapRef` par `ticket-config`. |
| 3 | `Running`, mais `0/1` READY | `kubectl --context minikube describe pods -n cinema-exam -l app=ticket-debug`, puis lecture des événements et des logs | La readinessProbe appelle le port `8081`, alors que Tomcat écoute sur `8080` : connexion refusée. | Remplacer le port de la readinessProbe par `8080`. |

#### Deuxième problème : référence de ConfigMap

Après application de la première correction, le nouveau Pod dépasse le téléchargement de l'image, mais ne peut pas encore créer son conteneur :

```text
NAME                            READY   STATUS                       RESTARTS   AGE
ticket-debug-6bc9655bd5-zmngr   0/1     ErrImagePull                 0          3m23s
ticket-debug-748f79d8cf-t89g2   0/1     CreateContainerConfigError   0          21s
```

L'ancien Pod utilise encore la politique `Always`. Le nouveau utilise bien `IfNotPresent`, mais référence toujours `ticket-configmap`. La vérification des événements de ce nouveau Pod indique :

```powershell
kubectl --context minikube get events -n cinema-exam --field-selector involvedObject.name=ticket-debug-748f79d8cf-t89g2 -o wide
kubectl --context minikube get configmaps -n cinema-exam
```

```text
Container image "ticket-service:1.0.0" already present on machine and can be accessed by the pod
Error: configmap "ticket-configmap" not found
```

La liste des ConfigMaps contient `ticket-config`, qui fournit `MOVIE_URL: http://movie:8080`. La deuxième correction remplace uniquement la référence `ticket-configmap` par `ticket-config`.

#### Troisième problème : port de la readinessProbe

Après application de la deuxième correction, le nouveau conteneur démarre, mais reste non prêt :

```text
NAME                            READY   STATUS                       RESTARTS   AGE
ticket-debug-748f79d8cf-t89g2   0/1     CreateContainerConfigError   0          3m25s
ticket-debug-c9999c4dc-fzdbq    0/1     Running                      0          41s
```

Le nouveau Pod utilise bien `ticket-config`. Les événements montrent cette fois l'erreur suivante :

```text
Readiness probe failed: Get "http://10.244.0.14:8081/actuator/health/readiness": dial tcp 10.244.0.14:8081: connect: connection refused
```

La lecture des logs confirme le port réel de l'application :

```powershell
kubectl --context minikube logs ticket-debug-c9999c4dc-fzdbq -n cinema-exam --tail=30
```

Extrait :

```text
Tomcat started on port 8080 (http) with context path '/'
```

La troisième correction remplace uniquement le port `8081` par `8080` dans la readinessProbe. Le statut `Running` indique que le conteneur fonctionne ; il ne suffit pas à rendre le Pod prêt si la probe appelle le mauvais port.

#### Validation après les trois corrections

Commandes exécutées :

```powershell
kubectl --context minikube apply -f broken/ticket-debug.yaml
kubectl --context minikube rollout status deployment/ticket-debug -n cinema-exam --timeout=180s
kubectl --context minikube get pods -n cinema-exam -l app=ticket-debug
kubectl --context minikube exec -n cinema-exam deploy/ticket-debug -- wget -qO- http://localhost:8080/actuator/health/readiness
```

Résultat du rollout :

```text
deployment "ticket-debug" successfully rolled out
```

Pod final :

```text
NAME                           READY   STATUS    RESTARTS   AGE
ticket-debug-56f4f5848-zlrtc   1/1     Running   0          8s
```

Readiness :

```json
{"status":"UP","components":{"movie":{"status":"UP"},"readinessState":{"status":"UP"}}}
```

Les trois corrections sont appliquées : `IfNotPresent`, référence à `ticket-config` et readiness sur le port 8080. Le Deployment a un réplica prêt et disponible.

#### Nettoyage du Deployment de dépannage

Après validation, le Deployment ticket-debug a été supprimé comme demandé :

```powershell
kubectl --context minikube delete -f broken/ticket-debug.yaml
kubectl --context minikube get deployment -n cinema-exam
kubectl --context minikube get pods -n cinema-exam
```

```text
deployment.apps "ticket-debug" deleted from cinema-exam namespace

NAME     READY   UP-TO-DATE   AVAILABLE   AGE
movie    2/2     2            2           49m
ticket   2/2     2            2           44m

NAME                      READY   STATUS    RESTARTS   AGE
movie-59684459f4-76zpj    1/1     Running   0          12m
movie-59684459f4-thql2    1/1     Running   0          12m
ticket-66d95c98b6-djfpb   1/1     Running   0          44m
ticket-66d95c98b6-lrtwv   1/1     Running   0          44m
```

Le fichier corrigé est conservé dans le dépôt. Le cluster ne contient plus que les deux Deployments de l'application.

### 6.3 — Changement de configuration sans rebuild

Avant le changement, la ConfigMap movie-config et l'API whoami indiquent toutes les deux `kubernetes`. Dans `10-config.yaml`, la valeur de `MOVIE_ENVIRONMENT` est changée en `production` pour cette expérience.

#### Observation après modification de la ConfigMap

Commandes exécutées avant de redémarrer les Pods :

```powershell
kubectl --context minikube apply -f k8s/10-config.yaml
kubectl --context minikube get configmap movie-config -n cinema-exam -o yaml
curl.exe -6 --noproxy "*" --max-time 10 -sS http://cinema.local/api/movies/whoami
```

Résultat de l'application :

```text
configmap/movie-config configured
configmap/ticket-config unchanged
```

La ConfigMap du cluster contient bien la nouvelle valeur :

```yaml
data:
  MOVIE_ENVIRONMENT: production
```

Mais l'ancien Pod répond encore :

```json
{"hostname":"movie-59684459f4-76zpj","environment":"kubernetes"}
```

La modification de la ConfigMap n'a donc pas changé la valeur déjà utilisée par le processus en cours.

#### Observation après renouvellement des Pods

Commandes exécutées :

```powershell
kubectl --context minikube rollout restart deployment/movie -n cinema-exam
kubectl --context minikube rollout status deployment/movie -n cinema-exam --timeout=180s
kubectl --context minikube get pods -n cinema-exam
curl.exe -6 --noproxy "*" --max-time 10 -sS http://cinema.local/api/movies/whoami
```

Résultat du rollout :

```text
deployment "movie" successfully rolled out
```

Les nouveaux Pods movie sont prêts et les Pods ticket restent inchangés :

```text
NAME                      READY   STATUS    RESTARTS   AGE
movie-7f49587d96-f47xd    1/1     Running   0          6s
movie-7f49587d96-sz6wh    1/1     Running   0          10s
ticket-66d95c98b6-djfpb   1/1     Running   0          47m
ticket-66d95c98b6-lrtwv   1/1     Running   0          47m
```

Réponse de whoami après le redémarrage :

```json
{"hostname":"movie-7f49587d96-f47xd","environment":"production"}
```

Une vérification complémentaire confirme `production` sur chacun des deux nouveaux Pods movie. Le Deployment utilise toujours `movie-service:1.0.0` et `/api/tickets` répond en HTTP 200. Aucune reconstruction d'image n'a été nécessaire.

### Q6.3 — Prise en compte de la ConfigMap

La ConfigMap est utilisée via `envFrom` : Kubernetes injecte ses valeurs dans les variables d'environnement au lancement du conteneur. Modifier la ConfigMap ne met pas à jour les variables du processus déjà en cours. Les anciens Pods conservaient donc `MOVIE_ENVIRONMENT=kubernetes`.

`kubectl rollout restart deployment/movie` a créé de nouveaux Pods, dont les conteneurs ont reçu la valeur actuelle `production`. Spring Boot l'a lue au démarrage. La configuration est séparée de l'image : il suffit de renouveler les Pods pour ce changement, sans recompiler le code ni reconstruire l'image. Voir la [documentation Kubernetes sur les ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/#using-configmaps).

## Partie 7 — Questions de synthèse

### Q7.1 — Trajet d'un appel de ticket vers movie

Le résolveur DNS du Pod utilise CoreDNS pour résoudre `movie`, étendu en `movie.cinema-exam.svc.cluster.local`, vers le ClusterIP du Service movie : `10.110.158.150`.
Le client envoie sa requête HTTP à cette adresse sur le port 8080.
Les règles réseau installées par kube-proxy pour le Service choisissent un Pod movie prêt parmi ses endpoints et acheminent la connexion vers son port nommé `http`, qui correspond à 8080.
Spring Boot dans ce Pod traite `/api/movies/1` et renvoie la réponse à ticket. Voir les documentations Kubernetes sur le [DNS](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/#services) et le [routage des Services](https://kubernetes.io/docs/reference/networking/virtual-ips/).

### Vérifications pour Q7.2

J'ai créé quatre réservations en passant par l'Ingress :

```powershell
$body = '{"movieId":1,"seats":1}'
1..4 | ForEach-Object {
    (Invoke-WebRequest -UseBasicParsing -Method Post -Uri http://cinema.local/api/tickets -ContentType "application/json" -Body $body).Content
}
```

```json
{"id":3,"movieId":1,"movieTitle":"Pod Fiction","seats":1,"total":10.50,"createdAt":"2026-10-08T12:22:59.279686260Z"}
{"id":1,"movieId":1,"movieTitle":"Pod Fiction","seats":1,"total":10.50,"createdAt":"2026-10-08T12:22:59.396542552Z"}
{"id":4,"movieId":1,"movieTitle":"Pod Fiction","seats":1,"total":10.50,"createdAt":"2026-10-08T12:22:59.449639803Z"}
{"id":2,"movieId":1,"movieTitle":"Pod Fiction","seats":1,"total":10.50,"createdAt":"2026-10-08T12:22:59.471765956Z"}
```

Puis j'ai consulté huit fois le nombre de réservations :

```powershell
1..8 | ForEach-Object {
    (Invoke-RestMethod -Uri http://cinema.local/api/tickets -TimeoutSec 10).Count
}
```

```text
4
2
4
2
4
2
4
2
```

Avant ce test, les listes contenaient déjà deux réservations sur une instance et aucune sur l'autre, issues des tests précédents. Les quatre nouvelles réservations se sont réparties à raison de deux par instance.

### Q7.2 — Réservations en mémoire

La liste n'est pas identique : les réponses alternent entre quatre et deux réservations, car les requêtes atteignent des Pods ticket différents.
Chaque instance possède sa propre liste en mémoire et son propre compteur d'identifiants dans `TicketController` ; ces données ne sont pas partagées entre les réplicas.
Si je supprime tous les Pods ticket, leurs remplaçants repartent avec une liste vide et un compteur réinitialisé : les réservations sont perdues.
Pour les conserver et obtenir une liste commune, il faut une base de données persistante partagée par les instances, qui gère aussi des identifiants uniques et les transactions.

### Vérifications pour Q7.3

J'ai supprimé un seul Pod movie :

```powershell
kubectl --context minikube delete pod movie-7f49587d96-f47xd -n cinema-exam
kubectl --context minikube get pods -n cinema-exam -l app=movie
```

```text
pod "movie-7f49587d96-f47xd" deleted from cinema-exam namespace
NAME                     READY   STATUS    RESTARTS   AGE
movie-7f49587d96-sthpc   0/1     Running   0          3s
movie-7f49587d96-sz6wh   1/1     Running   0          13m
```

Le nouveau Pod est apparu automatiquement. J'ai attendu qu'il soit prêt :

```powershell
kubectl --context minikube wait pod -n cinema-exam -l app=movie --for=condition=Ready --timeout=180s
kubectl --context minikube get pods -n cinema-exam
```

```text
pod/movie-7f49587d96-sthpc condition met
pod/movie-7f49587d96-sz6wh condition met
NAME                      READY   STATUS    RESTARTS   AGE
movie-7f49587d96-sthpc    1/1     Running   0          10s
movie-7f49587d96-sz6wh    1/1     Running   0          13m
ticket-66d95c98b6-djfpb   1/1     Running   0          61m
ticket-66d95c98b6-lrtwv   1/1     Running   0          61m
```

Une vérification des `ownerReferences` confirme que le nouveau Pod appartient au ReplicaSet `movie-7f49587d96`. Celui-ci affiche deux réplicas souhaités, deux présents et deux prêts. Les Deployments movie et ticket sont tous deux à `2/2`.

### Q7.3 — Remplacement d'un Pod supprimé

Après la suppression de `movie-7f49587d96-f47xd`, un nouveau Pod, `movie-7f49587d96-sthpc`, est apparu puis est devenu prêt.
Le ReplicaSet géré par le Deployment maintient les deux réplicas souhaités : il crée un remplaçant lorsqu'un Pod manque.
Avec un Pod nu sans contrôleur, sa suppression ne déclencherait aucune recréation ; je perdrais aussi la gestion des réplicas et des mises à jour progressives offerte par le Deployment.
La politique de redémarrage peut relancer un conteneur dans un Pod existant, mais elle ne recrée pas un Pod supprimé. Voir les documentations Kubernetes sur les [ReplicaSets](https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/) et le [cycle de vie des Pods](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/).

## Bonus — Durcir et fiabiliser

### B1 — Sécurité du conteneur movie

Dans `k8s/20-movie.yaml`, le `securityContext` du conteneur movie impose `runAsNonRoot: true` et `runAsUser: 10001`. L'UID correspond à l'utilisateur spring déjà présent dans l'image.

`allowPrivilegeEscalation: false` interdit au processus de gagner des privilèges supplémentaires, `capabilities.drop: [ALL]` retire les capabilities Linux et `readOnlyRootFilesystem: true` rend le système de fichiers racine du conteneur non modifiable.

J'ai aussi ajouté un volume `emptyDir` au niveau du Pod, monté sur `/tmp` dans le conteneur. Tomcat dispose ainsi d'un emplacement temporaire accessible en écriture malgré la racine en lecture seule. Ce volume est propre à chaque Pod et ses données sont supprimées avec celui-ci ; il ne sert pas à conserver des réservations. Voir les documentations Kubernetes sur le [securityContext](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/) et les [volumes emptyDir](https://kubernetes.io/docs/concepts/storage/volumes/#emptydir).

#### Vérifications de B1

J'ai appliqué le manifeste et attendu la fin du déploiement :

```powershell
kubectl --context minikube apply -f k8s/20-movie.yaml
kubectl --context minikube rollout status deployment/movie -n cinema-exam --timeout=180s
kubectl --context minikube get pods -n cinema-exam
```

```text
deployment.apps/movie configured
service/movie unchanged
deployment "movie" successfully rolled out
NAME                      READY   STATUS    RESTARTS   AGE
movie-75587c7dff-jf7js    1/1     Running   0          10s
movie-75587c7dff-w9g72    1/1     Running   0          6s
ticket-66d95c98b6-djfpb   1/1     Running   0          64m
ticket-66d95c98b6-lrtwv   1/1     Running   0          64m
```

Contrôle de l'utilisateur et tentative d'écriture à la racine :

```powershell
kubectl --context minikube exec -n cinema-exam deploy/movie -- id
kubectl --context minikube exec -n cinema-exam deploy/movie -- touch /test
```

```text
uid=10001(spring) gid=101(spring) groups=101(spring)
touch: cannot touch '/test': Read-only file system
command terminated with exit code 1
```

Le code de sortie 1 est attendu pour ce test : l'écriture de `/test` est refusée car la racine est en lecture seule. Les Pods restent prêts, sans redémarrage.

Une vérification complémentaire des deux Pods confirme tous les champs du `securityContext` ainsi que le volume `emptyDir` monté sur `/tmp`. L'API reste accessible via l'Ingress :

```powershell
curl.exe -6 --noproxy "*" --max-time 10 -sS -o NUL -w "%{http_code}\n" http://cinema.local/api/movies
curl.exe -6 --noproxy "*" --max-time 10 -sS http://cinema.local/api/movies/whoami
```

```text
200
{"hostname":"movie-75587c7dff-jf7js","environment":"production"}
```

### B2 — Mise à jour progressive sous trafic

J'ai ajouté une stratégie explicite au Deployment movie :

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 1
```

`maxUnavailable: 0` demande de maintenir les deux réplicas disponibles pendant la mise à jour. `maxSurge: 1` autorise un réplica supplémentaire pour démarrer un remplaçant avant de retirer un ancien Pod. La readiness utilise toujours `/actuator/health/readiness`, et `server.shutdown: graceful` est déjà configuré dans movie. Voir les documentations sur les [RollingUpdates Kubernetes](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-update-deployment) et l'[arrêt gracieux Spring Boot](https://docs.spring.io/spring-boot/3.5/reference/web/graceful-shutdown.html).

#### Vérification de la stratégie appliquée

```powershell
kubectl --context minikube apply -f k8s/20-movie.yaml
kubectl --context minikube get deployment movie -n cinema-exam -o jsonpath='{.spec.strategy}'
kubectl --context minikube get pods -n cinema-exam -l app=movie
```

```text
deployment.apps/movie configured
service/movie unchanged
{"rollingUpdate":{"maxSurge":1,"maxUnavailable":0},"type":"RollingUpdate"}
NAME                     READY   STATUS    RESTARTS   AGE
movie-75587c7dff-jf7js   1/1     Running   0          3m26s
movie-75587c7dff-w9g72   1/1     Running   0          3m22s
```

La modification de la stratégie seule n'a pas renouvelé les Pods : leurs noms sont identiques à ceux du test B1. Le remplacement sera déclenché par `kubectl rollout restart` pendant le test HTTP.

#### Délai observé pendant le premier test simultané

La boucle HTTP a commencé à `2026-10-08T14:38:57.1902609+02:00` et le redémarrage a été lancé après `2026-10-08T14:39:07.4376935+02:00`. Le rollout s'est terminé avant `2026-10-08T14:39:16.7369369+02:00`, mais curl a signalé un dépassement du délai de 10 secondes :

```text
curl: (28) Operation timed out after 10015 milliseconds with 0 bytes received
```

Les logs de l'Ingress montrent des délais de connexion vers les anciens Pods movie, dont les adresses étaient `10.244.0.21` et `10.244.0.22` :

```text
2026/10/08 12:39:17 [error] 162#162: *44492 upstream timed out (110: Operation timed out) while connecting to upstream, client: 127.0.0.1, server: cinema.local, request: "GET /api/movies HTTP/1.1", upstream: "http://10.244.0.21:8080/api/movies", host: "cinema.local"
2026/10/08 12:39:22 [error] 162#162: *44492 upstream timed out (110: Operation timed out) while connecting to upstream, client: 127.0.0.1, server: cinema.local, request: "GET /api/movies HTTP/1.1", upstream: "http://10.244.0.22:8080/api/movies", host: "cinema.local"
```

Les logs de l'Ingress sont en UTC, soit deux heures de moins que les horaires PowerShell. Les nouveaux Pods `movie-77d677cd74-jx8nz` et `movie-77d677cd74-ng5vq` sont prêts, sans redémarrage, et leurs endpoints sont prêts. Une requête de contrôle répond HTTP 200.

Pour laisser le temps au routage de prendre en compte le retrait d'un Pod avant l'arrêt de Tomcat, j'ai ajouté au conteneur un hook `preStop` qui exécute `sleep 10`. Le Pod dispose de `terminationGracePeriodSeconds: 40`, car le délai du hook fait partie de la période de terminaison ; il reste ensuite du temps pour l'arrêt gracieux de Spring Boot. Le retrait des endpoints et l'arrêt local du conteneur se déroulent en parallèle, comme l'explique la [documentation Kubernetes sur la terminaison des Pods](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination-flow). Le test HTTP doit être refait après application pour vérifier l'effet de ce changement.

Après application de ce changement et attente du rollout, les Pods sont :

```text
NAME                      READY   STATUS    RESTARTS   AGE
movie-7cf84bb4fc-df8sp    1/1     Running   0          8s
movie-7cf84bb4fc-xxqlx    1/1     Running   0          15s
ticket-66d95c98b6-djfpb   1/1     Running   0          74m
ticket-66d95c98b6-lrtwv   1/1     Running   0          74m
```

Le contrôle de leur configuration confirme `preStop: sleep 10` et `terminationGracePeriodSeconds: 40` sur chacun des deux Pods movie. La stratégie reste `RollingUpdate` avec `maxUnavailable: 0` et `maxSurge: 1`. L'API répond HTTP 200 avant le nouveau test sous trafic.

#### Test simultané après ajout du délai preStop

Dans un terminal, j'ai lancé les 300 requêtes via l'Ingress :

```powershell
Get-Date -Format o
1..300 | ForEach-Object {
    curl.exe -6 --noproxy "*" --max-time 10 -sS -o NUL -w "%{http_code}\n" http://cinema.local/api/movies
    Start-Sleep -Milliseconds 200
} | Group-Object | Select-Object Count, Name
Get-Date -Format o
```

L'heure relevée avant la boucle était `2026-10-08T14:43:42.3225306+02:00`. Pendant qu'elle tournait, j'ai exécuté dans un autre terminal :

```powershell
Get-Date -Format o
kubectl --context minikube rollout restart deployment/movie -n cinema-exam
kubectl --context minikube rollout status deployment/movie -n cinema-exam --timeout=180s
Get-Date -Format o
kubectl --context minikube get pods -n cinema-exam
```

```text
2026-10-08T14:43:51.5972623+02:00
deployment.apps/movie restarted
deployment "movie" successfully rolled out
2026-10-08T14:44:05.2046439+02:00
NAME                      READY   STATUS        RESTARTS   AGE
movie-6dd5ff4bd5-8kgk9    1/1     Running       0          8s
movie-6dd5ff4bd5-wdnzj    1/1     Running       0          15s
movie-7cf84bb4fc-df8sp    1/1     Terminating   0          100s
movie-7cf84bb4fc-xxqlx    1/1     Terminating   0          107s
ticket-66d95c98b6-djfpb   1/1     Running       0          76m
ticket-66d95c98b6-lrtwv   1/1     Running       0          76m
```

Les anciens Pods encore en `Terminating` finissent leur arrêt ; le rollout est déjà terminé car les deux nouveaux réplicas sont disponibles. Une vérification ultérieure confirme la disparition des anciens Pods et les Deployments movie et ticket à `2/2`, sans redémarrage des conteneurs restants.

Le résultat a été vérifié indépendamment en comptant, dans les logs de l'Ingress, les requêtes `GET /api/movies` entre `12:43:42Z` et `12:45:35Z` le 8 octobre 2026. Le comptage donne :

```text
Count Name
----- ----
  300 200
```

La première réponse est enregistrée à `12:43:42Z` et la dernière à `12:44:59Z`, soit de 14:43:42 à 14:44:59 en heure locale. Cet intervalle couvre le redémarrage. Les logs montrent le passage des anciennes adresses de Pods aux nouvelles `10.244.0.27` et `10.244.0.28`. Aucune ligne d'erreur n'est présente sur cette période et la durée maximale enregistrée pour ces requêtes est de `0.044` seconde.

### QB2 — Résultat et rôle des trois éléments

Après ajout du délai preStop, les logs de l'Ingress confirment 300 réponses HTTP 200 pendant le remplacement des Pods, sans erreur observée sur ce test.
La stratégie `RollingUpdate`, avec `maxUnavailable: 0` et `maxSurge: 1`, permet de démarrer un remplaçant avant de retirer un ancien réplica disponible.
La `readinessProbe` empêche d'envoyer le trafic aux nouveaux Pods tant que leur application n'est pas prête.
`shutdown: graceful` laisse les requêtes en cours se terminer avant l'arrêt de l'application, au lieu de les interrompre.
Dans cet environnement, le délai `preStop` de 10 secondes complète ces mécanismes en laissant le routage prendre en compte le retrait du Pod avant que Tomcat cesse d'accepter des requêtes. Le résultat décrit cette mesure locale ; il ne garantit pas l'absence d'erreur dans toutes les conditions.
