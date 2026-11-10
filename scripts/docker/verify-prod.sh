#!/usr/bin/env bash
# Valida imágenes ya publicadas en GHCR contra docker-compose.prod.yaml.
# No compila. El trap no baja la pila salvo --down.

set -euo pipefail

BACKEND_REPO="ghcr.io/ario-weareadn/qrcodly-backend"
FRONTEND_REPO="ghcr.io/ario-weareadn/qrcodly-frontend"
PROJECT_NAME="qrcodly-prod"

CALLER_PWD="$(pwd)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$ROOT/docker-compose.prod.yaml"
ENV_FILE=".env.production"
TAG="latest"
DOWN=0
FAILED=0
PULL_CFG=""

declare -a REPORT=()
declare -a TMP_PATHS=()

# shellcheck disable=SC2329 # the EXIT trap calls it
cleanup() {
	local status=$?
	set +e
	if [[ "$DOWN" -eq 1 && -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
		env -u COMPOSE_FILE "QRCODLY_TAG=$TAG" \
			docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down >/dev/null 2>&1
	fi
	if [[ ${#TMP_PATHS[@]} -gt 0 ]]; then
		rm -rf "${TMP_PATHS[@]}"
	fi
	exit "$status"
}

die() {
	echo "FALLO: $*" >&2
	exit 1
}

pass() {
	REPORT+=("OK    $1")
}

fail() {
	REPORT+=("FALLO $1")
	FAILED=1
}

finish() {
	echo
	echo "Resumen"
	if [[ ${#REPORT[@]} -gt 0 ]]; then
		printf '%s\n' "${REPORT[@]}"
	fi
	exit "$FAILED"
}

compose() {
	env -u COMPOSE_FILE "QRCODLY_TAG=$TAG" \
		docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

# Lee el JSON pretty-printed de `docker compose config --format json`
# y escribe "servicio|host_ip|published|target". El host vacío se conserva.
ports_from_config_json() {
	awk '
		/^    "[A-Za-z0-9_-]+": \{$/ {
			svc = $0
			sub(/^    "/, "", svc)
			sub(/": \{$/, "", svc)
		}
		/^      "ports": \[$/ {
			in_ports = 1
			next
		}
		in_ports && /^      \][,]?$/ {
			in_ports = 0
			next
		}
		in_ports && /^        \{$/ {
			host = ""
			pub = ""
			tgt = ""
			next
		}
		in_ports && /^          "host_ip":/ {
			host = $0
			sub(/^          "host_ip": "/, "", host)
			sub(/",?$/, "", host)
			next
		}
		in_ports && /^          "published":/ {
			pub = $0
			sub(/^          "published": /, "", pub)
			gsub(/[",]/, "", pub)
			next
		}
		in_ports && /^          "target":/ {
			tgt = $0
			sub(/^          "target": /, "", tgt)
			gsub(/[",]/, "", tgt)
			next
		}
		in_ports && /^        \}[,]?$/ {
			printf "%s|%s|%s|%s\n", svc, host, pub, tgt
			next
		}
	'
}

host_label() {
	local host_ip="$1"
	if [[ -z "$host_ip" || "$host_ip" == "0.0.0.0" || "$host_ip" == "::" || "$host_ip" == "[::]" ]]; then
		printf 'todas las interfaces'
		return
	fi
	printf '%s' "$host_ip"
}

forbidden_port() {
	case "$1" in
	3306 | 6379 | 9001) return 0 ;;
	*) return 1 ;;
	esac
}

# Lee "servicio|host_ip|published|target". Un puerto fuera de 127.0.0.1,
# o MySQL/Redis/consola de MinIO, sale como AVISO. No es un fallo.
port_warnings() {
	local service host_ip published target where
	while IFS='|' read -r service host_ip published target; do
		[[ -z "$service" ]] && continue
		where="$(host_label "$host_ip")"
		if forbidden_port "$published" || forbidden_port "$target"; then
			printf 'AVISO %s publica %s->%s en %s. MySQL, Redis y la consola de MinIO no deben estar expuestos.\n' \
				"$service" "${published:-?}" "${target:-?}" "$where"
		elif [[ "$host_ip" != "127.0.0.1" ]]; then
			printf 'AVISO %s publica %s->%s en %s, fuera de 127.0.0.1.\n' \
				"$service" "${published:-?}" "${target:-?}" "$where"
		fi
	done
}

# El aviso no pone FAILED. Un fallo aquí es no poder leer los puertos.
check_ports() {
	local json published parsed count line warnings
	if ! json="$(compose config --no-interpolate --no-env-resolution --format json)"; then
		fail "no se ha podido leer docker compose config para revisar los puertos"
		return
	fi
	published="$(printf '%s\n' "$json" | grep -c '"published"' || true)"
	parsed="$(printf '%s\n' "$json" | ports_from_config_json)"
	count=0
	if [[ -n "$parsed" ]]; then
		count="$(printf '%s\n' "$parsed" | wc -l)"
		count="${count//[[:space:]]/}"
	fi
	if [[ "$published" != "$count" ]]; then
		fail "no se han podido leer los puertos de docker compose config (published=${published}, filas=${count})"
		return
	fi
	warnings="$(printf '%s\n' "$parsed" | port_warnings)"
	if [[ -z "$warnings" ]]; then
		pass "puertos publicados solo en 127.0.0.1; MySQL, Redis y la consola de MinIO no están expuestos"
		return
	fi
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		REPORT+=("$line")
	done <<<"$warnings"
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
	return 0
fi

usage_error() {
	die "opción desconocida: $1 (vale --tag, --env-file y --down)"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--tag)
		if [[ $# -lt 2 ]]; then
			die "falta el valor tras --tag"
		fi
		TAG="$2"
		shift 2
		;;
	--env-file)
		if [[ $# -lt 2 ]]; then
			die "falta la ruta tras --env-file"
		fi
		ENV_FILE="$2"
		shift 2
		;;
	--down)
		DOWN=1
		shift
		;;
	*)
		usage_error "$1"
		;;
	esac
done

if [[ ! "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
	die "tag no válido: ${TAG}"
fi

if [[ "$ENV_FILE" != /* ]]; then
	ENV_FILE="$CALLER_PWD/$ENV_FILE"
fi

cd "$ROOT"
trap cleanup EXIT

if [[ ! -f "$COMPOSE_FILE" ]]; then
	die "no está docker-compose.prod.yaml en ${ROOT}"
fi

if ! command -v docker >/dev/null 2>&1; then
	die "no se encuentra el ejecutable docker"
fi

if ! command -v curl >/dev/null 2>&1; then
	die "no se encuentra curl"
fi

docker_err="$(mktemp)"
TMP_PATHS+=("$docker_err")
if ! docker info >"$docker_err" 2>&1; then
	echo "FALLO: el daemon de Docker no responde. Comprueba que está en marcha y que DOCKER_HOST apunta a un socket válido." >&2
	if ! grep -E 'failed to connect|Cannot connect|error during connect|no such file or directory' "$docker_err" | head -n 1 >&2; then
		tail -n 1 "$docker_err" >&2 || true
	fi
	exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
	fail "no existe el env file ${ENV_FILE}. Cópialo desde .env.production.example o pasa --env-file."
	finish
fi

config_err="$(mktemp)"
TMP_PATHS+=("$config_err")
if compose config -q >"$config_err" 2>&1; then
	pass "compose config -q con --env-file (variables :? definidas)"
else
	echo "FALLO: docker compose config no interpola ${COMPOSE_FILE} con --env-file ${ENV_FILE}." >&2
	echo "Pista: define en ese fichero las variables que el compose marca con :? . --env-file es el que rellena el YAML; el env_file de cada servicio no." >&2
	while IFS= read -r line; do
		if [[ ${#line} -le 400 ]] && [[ "$line" == *[Ee]rror* || "$line" == *"required variable"* || "$line" == *"env file"* || "$line" == *"invalid"* ]]; then
			printf '%s\n' "$line" >&2
		fi
	done <"$config_err"
	missing="$(
		grep -oE 'required variable [A-Za-z_][A-Za-z0-9_]*' "$config_err" |
			awk '{ if (!seen[$3]++) { printf "%s%s", sep, $3; sep=", " } }' || true
	)"
	if [[ -n "$missing" ]]; then
		fail "compose config: faltan variables obligatorias (${missing}). Defínelas en el env file."
	else
		fail "compose config no ha podido interpolar el YAML. Revisa el env file y los :? de docker-compose.prod.yaml."
	fi
	finish
fi

PULL_CFG="$(mktemp -d)"
TMP_PATHS+=("$PULL_CFG")

pull_one() {
	local image="$1"
	local log
	log="$(mktemp)"
	TMP_PATHS+=("$log")
	echo "Descargando ${image} sin login..."
	if DOCKER_CONFIG="$PULL_CFG" docker pull "$image" >"$log" 2>&1; then
		pass "pull anónimo de ${image}"
		return 0
	fi
	cat "$log" >&2
	if grep -F -q 'manifest unknown' "$log"; then
		fail "pull de ${image}: manifest unknown. El tag no existe. Mira Packages o publica el workflow."
	elif grep -E -i -q 'denied|unauthorized' "$log"; then
		fail "pull de ${image}: denied. El paquete sigue privado. El tag no existe también responde denied en un pull sin login; publícalo o abre el paquete (Package settings → Public)."
	else
		fail "pull de ${image} falló. Mira la salida de docker pull."
	fi
	return 1
}

pull_failed=0
pull_one "${BACKEND_REPO}:${TAG}" || pull_failed=1
pull_one "${FRONTEND_REPO}:${TAG}" || pull_failed=1
if [[ "$pull_failed" -ne 0 ]]; then
	echo "No se ejecuta up: el pull ha fallado." >&2
	check_ports
	finish
fi

check_image_metadata() {
	local image="$1"
	local user source
	user="$(docker image inspect -f '{{.Config.User}}' "$image")"
	source="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.source"}}' "$image")"
	if [[ "$user" == "1000" ]]; then
		pass "User de ${image} es 1000"
	else
		fail "User de ${image} es '${user:-vacío}', se esperaba 1000. La imagen tiene que construirse con USER 1000."
	fi
	if [[ -n "$source" && "$source" != "<no value>" ]]; then
		pass "org.opencontainers.image.source de ${image} (${source})"
	else
		fail "a ${image} le falta org.opencontainers.image.source. La pone el workflow docker-publish (docker/metadata-action)."
	fi
}

check_image_metadata "${BACKEND_REPO}:${TAG}"
check_image_metadata "${FRONTEND_REPO}:${TAG}"

echo "Arrancando la pila con ${TAG}..."
if compose up -d --wait; then
	pass "up -d --wait"
else
	echo "FALLO: up -d --wait no dejó la pila sana." >&2
	compose ps -a >&2 || true
	echo "Pista: si backend queda unhealthy, falta una variable de runtime en el env file." >&2
	fail "up -d --wait no dejó la pila sana"
fi

check_healthy() {
	local service="$1"
	local cid status
	cid="$(compose ps -aq "$service" || true)"
	cid="${cid%%$'\n'*}"
	if [[ -z "$cid" ]]; then
		fail "${service} no tiene contenedor. Mira: docker compose -f docker-compose.prod.yaml --env-file <env> ps -a"
		return
	fi
	status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
	if [[ "$status" == "healthy" ]]; then
		pass "${service} healthy"
	else
		fail "${service} está '${status}', se esperaba healthy. Si es backend, suele faltar una variable de runtime en el env file."
	fi
}

check_exited_ok() {
	local service="$1"
	local cid state
	cid="$(compose ps -aq "$service" || true)"
	cid="${cid%%$'\n'*}"
	if [[ -z "$cid" ]]; then
		fail "${service} no tiene contenedor. Mira: docker compose -f docker-compose.prod.yaml --env-file <env> ps -a"
		return
	fi
	state="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$cid")"
	if [[ "$state" == "exited 0" ]]; then
		pass "${service} terminó con exit 0"
	else
		fail "${service} terminó en '${state}', se esperaba exited 0"
	fi
}

check_healthy db
check_healthy redis
check_healthy minio
check_healthy backend
check_healthy frontend
check_exited_ok migrate
check_exited_ok minio-setup

check_http() {
	local url="$1"
	local code
	code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url" || true)"
	if [[ "$code" == "200" ]]; then
		pass "GET ${url}"
	else
		fail "GET ${url} devolvió ${code:-sin respuesta}. Si el frontend apunta a otra API, FRONTEND_BUILD_ARGS está mal y hay que relanzar el workflow."
	fi
}

check_http "http://127.0.0.1:5001/api/v1"
check_http "http://127.0.0.1:3000/"

check_history() {
	local image="$1"
	local hist
	if ! hist="$(docker history --no-trunc --format '{{.CreatedBy}} {{.Comment}}' "$image" 2>&1)"; then
		fail "docker history de ${image} falló"
		return
	fi
	# <missing> en la columna IMAGE es normal en una imagen solo descargada.
	# Aquí no se mira esa columna: el fallo es un build local escrito en la capa.
	if printf '%s\n' "$hist" | grep -E -q 'docker[[:space:]]+build([^[:alnum:]_]|$)|docker[[:space:]]+buildx[[:space:]]+build|docker[[:space:]]+compose[[:space:]]+build|docker-compose[[:space:]]+build|load build context|transferring context|build context'; then
		fail "docker history de ${image} indica un build local (docker build o contexto local). Tiene que ser un pull de GHCR."
	else
		pass "docker history de ${image} no muestra un build local"
	fi
}

check_compose_images() {
	local rows name repo tag service
	local saw_backend=0 saw_frontend=0
	rows="$(compose images | awk 'NR > 1 && NF >= 3 { printf "%s|%s|%s\n", $1, $2, $3 }')"
	if [[ -z "$rows" ]]; then
		fail "docker compose images no lista contenedores. La pila no llegó a crear backend ni frontend."
		return
	fi
	while IFS='|' read -r name repo tag; do
		[[ -z "$name" ]] && continue
		service="${name#"${PROJECT_NAME}-"}"
		service="${service%-[0-9]*}"
		case "$service" in
		backend | migrate)
			if [[ "$repo" == "$BACKEND_REPO" ]]; then
				pass "compose images: ${service} es ${repo}:${tag}"
			else
				fail "compose images: ${service} es '${repo}', se esperaba ${BACKEND_REPO}. Tiene que ser un pull de GHCR, no un build en esta máquina."
			fi
			if [[ "$service" == "backend" ]]; then
				saw_backend=1
			fi
			;;
		frontend)
			if [[ "$repo" == "$FRONTEND_REPO" ]]; then
				pass "compose images: ${service} es ${repo}:${tag}"
			else
				fail "compose images: ${service} es '${repo}', se esperaba ${FRONTEND_REPO}. Tiene que ser un pull de GHCR, no un build en esta máquina."
			fi
			saw_frontend=1
			;;
		esac
	done <<<"$rows"
	if [[ "$saw_backend" -eq 0 ]]; then
		fail "compose images no muestra ${BACKEND_REPO} para backend"
	fi
	if [[ "$saw_frontend" -eq 0 ]]; then
		fail "compose images no muestra ${FRONTEND_REPO} para frontend"
	fi
	check_history "${BACKEND_REPO}:${TAG}"
	check_history "${FRONTEND_REPO}:${TAG}"
}

check_compose_images

check_ports

finish
