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
