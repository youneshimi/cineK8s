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
