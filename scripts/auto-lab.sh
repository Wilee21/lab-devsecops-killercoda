#!/usr/bin/env bash
# Ejecuta el laboratorio completo sin intervención, cuidando la memoria (playground de ~2 GB).
# Orden: app (03, 04) primero; luego pausa el cluster y corre SonarQube (02).
# Uso: nohup bash scripts/auto-lab.sh > ~/lab/progreso.log 2>&1 &
set -u
cd "$(dirname "$0")/.."
chmod +x scripts/*.sh
SONAR_KEY=$(sed -n 's/^sonar.projectKey=//p' sonar-project.properties)
paso() { echo; echo "########## $1 ($(date +%T))"; }

paso "Liberar memoria"
timeout 120 docker rm -f sonarqube >/dev/null 2>&1
if ! timeout 20 docker ps >/dev/null 2>&1; then
  echo "Docker no responde: reiniciando"
  systemctl restart docker; sleep 15
fi
free -h | awk 'NR<=2'

if ! kind get clusters 2>/dev/null | grep -qx lab; then
  paso "00 Instalar herramientas"; ./scripts/00-instalar-herramientas.sh
  # El paso 00 puede salir con error solo al imprimir versiones (| head + pipefail); se valida lo importante:
  for t in docker kind kubectl trivy; do command -v "$t" >/dev/null || { echo "FALLO 00: falta $t"; exit 1; }; done
  sysctl -w vm.max_map_count=524288 >/dev/null
  paso "01 Crear cluster";         ./scripts/01-crear-cluster.sh         || { echo "FALLO 01"; exit 1; }
else
  docker start lab-control-plane >/dev/null 2>&1; sleep 30
  kubectl get nodes
fi

paso "03 Build y escaneo";  ./scripts/03-build-y-escaneo.sh || { echo "FALLO 03"; exit 1; }
paso "04 Desplegar";        ./scripts/04-desplegar.sh       || { echo "FALLO 04"; exit 1; }
paso "Verificar";           ./scripts/verificar.sh
paso "Evidencia de la app"
kubectl -n tareas get pods,svc
curl -s localhost:30080/api/health; echo

paso "Pausar cluster para dar memoria a SonarQube (se reanuda con: docker start lab-control-plane)"
docker stop lab-control-plane >/dev/null && echo "Cluster pausado"

paso "02 SonarQube"; ./scripts/02-sonarqube.sh || echo "FALLO 02"
sleep 20
paso "Resultados SonarQube"
curl -s -u "admin:DevOps2026!lab" "localhost:9000/api/qualitygates/project_status?projectKey=${SONAR_KEY}" | grep -o '"status":"[A-Z_]*"' | head -1
echo "-- Security Hotspots:"
curl -s -u "admin:DevOps2026!lab" "localhost:9000/api/hotspots/search?projectKey=${SONAR_KEY}&ps=20" | grep -o '"message":"[^"]*"'
echo "-- Issues:"
curl -s -u "admin:DevOps2026!lab" "localhost:9000/api/issues/search?componentKeys=${SONAR_KEY}&ps=20" | grep -o '"message":"[^"]*"'

echo
echo "=== TERMINADO ==="
