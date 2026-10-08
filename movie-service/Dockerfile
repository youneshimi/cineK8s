# Compilation du service
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app

COPY pom.xml ./pom.xml
RUN mvn -q -B dependency:go-offline

COPY src ./src
RUN mvn -q -B package -DskipTests

# Image d'exécution
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app

# Port utilisé dans Compose et Kubernetes
ENV SERVER_PORT=8080

RUN addgroup -S spring && adduser -S -u 10001 -G spring spring
USER spring

COPY --from=build /app/target/*.jar app.jar

EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "app.jar"]
