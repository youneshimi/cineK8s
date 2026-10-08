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
