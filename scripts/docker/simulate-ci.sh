#!/usr/bin/env bash
# Simula el build de CI en local: imágenes linux/amd64 y un stack efímero.

set -euo pipefail

CALLER_PWD="$(pwd)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

COMPOSE_FILE="$ROOT/docker-compose.ci.yaml"
BUILD_ARGS_FILE="$ROOT/.env.production"
KEEP=0
NO_CACHE=0
FRONTEND_SMOKE_NAME="qrcodly-ci-frontend-smoke"
FRONTEND_SMOKE_PORT=33173
SMOKE_ENV_FILE=""
FAILED=0
OPENAPI_URL="http://127.0.0.1:5001/api/v1/openapi.json"

declare -a REPORT=()
declare -A BUILD_ARGS=()

REQUIRED_KEYS=(
	NEXT_PUBLIC_FRONTEND_URL
	NEXT_PUBLIC_API_URL
	NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY
	NEXT_PUBLIC_SENTRY_DSN
	NEXT_PUBLIC_GOOGLE_API_KEY
	NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_MONTHLY
	NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_ANNUAL
	NEXT_PUBLIC_STRIPE_ADDON_DOMAIN_PRICE_ID_MONTHLY
	NEXT_PUBLIC_STRIPE_ADDON_DOMAIN_PRICE_ID_ANNUAL
)

FRONTEND_BUILD_ARG_KEYS=(
	NEXT_PUBLIC_FRONTEND_URL
	NEXT_PUBLIC_API_URL
	NEXT_PUBLIC_SHORT_URL_DOMAIN
	NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY
	NEXT_PUBLIC_CLERK_JS_URL
	NEXT_PUBLIC_POSTHOG_KEY
	NEXT_PUBLIC_POSTHOG_HOST
	NEXT_PUBLIC_SENTRY_DSN
	NEXT_PUBLIC_SENTRY_ENVIRONMENT
	NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_MONTHLY
	NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_ANNUAL
	NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_MONTHLY_LEGACY
	NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_ANNUAL_LEGACY
	NEXT_PUBLIC_STRIPE_ADDON_DOMAIN_PRICE_ID_MONTHLY
	NEXT_PUBLIC_STRIPE_ADDON_DOMAIN_PRICE_ID_ANNUAL
	NEXT_PUBLIC_GOOGLE_API_KEY
)

# shellcheck disable=SC2329 # the EXIT trap calls it
cleanup() {
	status=$?
	set +e
	if [[ "$KEEP" -eq 0 ]] && docker info >/dev/null 2>&1; then
		docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1
		docker rm -f "$FRONTEND_SMOKE_NAME" >/dev/null 2>&1
	fi
	if [[ -n "$SMOKE_ENV_FILE" ]]; then
		rm -f "$SMOKE_ENV_FILE"
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

while [[ $# -gt 0 ]]; do
	case "$1" in
	--build-args-file)
		if [[ $# -lt 2 ]]; then
			die "falta la ruta tras --build-args-file"
		fi
		BUILD_ARGS_FILE="$2"
		shift 2
		;;
	--keep)
		KEEP=1
		shift
		;;
	--no-cache)
		NO_CACHE=1
		shift
		;;
	*)
		die "opción desconocida: $1"
		;;
	esac
done

if [[ "$BUILD_ARGS_FILE" != /* ]]; then
	BUILD_ARGS_FILE="$CALLER_PWD/$BUILD_ARGS_FILE"
fi

trap cleanup EXIT

if [[ ! -f "$BUILD_ARGS_FILE" ]]; then
	die "no existe el fichero de build args: ${BUILD_ARGS_FILE}"
fi

if ! command -v docker >/dev/null 2>&1; then
	die "no se encuentra el ejecutable docker"
fi

if ! docker buildx version >/dev/null 2>&1; then
	die "docker buildx no está disponible"
fi

docker_err="$(mktemp)"
if ! docker info >"$docker_err" 2>&1; then
	echo "FALLO: el daemon de Docker no responde. Comprueba que está en marcha y que DOCKER_HOST apunta a un socket válido." >&2
	if ! grep -E 'failed to connect|Cannot connect|error during connect|no such file or directory' "$docker_err" | head -n 1 >&2; then
		tail -n 1 "$docker_err" >&2 || true
	fi
	rm -f "$docker_err"
	exit 1
fi
rm -f "$docker_err"

if ! command -v curl >/dev/null 2>&1; then
	die "no se encuentra curl"
fi

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

while IFS= read -r line || [[ -n "$line" ]]; do
	line="${line%$'\r'}"
	if [[ "$line" =~ ^[[:space:]]*# ]] || [[ "$line" =~ ^[[:space:]]*$ ]]; then
		continue
	fi
	line="$(trim "$line")"
	if [[ "$line" == export\ * ]]; then
		line="$(trim "${line#export }")"
	fi
	if [[ "$line" != *"="* ]]; then
		continue
	fi
	key="$(trim "${line%%=*}")"
	value="$(trim "${line#*=}")"
	if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
		continue
	fi
	if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
		value="${value:1:${#value}-2}"
	fi
	BUILD_ARGS["$key"]="$value"
done <"$BUILD_ARGS_FILE"

missing_keys=()
for key in "${REQUIRED_KEYS[@]}"; do
	if [[ -z "${BUILD_ARGS[$key]:-}" ]]; then
		missing_keys+=("$key")
	fi
done
if [[ ${#missing_keys[@]} -gt 0 ]]; then
	echo "FALLO: faltan claves NEXT_PUBLIC obligatorias, o están vacías, en ${BUILD_ARGS_FILE}:" >&2
	printf '  %s\n' "${missing_keys[@]}" >&2
	exit 1
fi

for key in "${!BUILD_ARGS[@]}"; do
	case "$key" in
	*_SECRET | *_PASSWORD)
		echo "Aviso: ${key} está en el fichero de build args. Ese fichero no debería contener secretos." >&2
		;;
	esac
done

if [[ ! -f "$ROOT/.dockerignore" ]] || ! grep -Eq '^[[:space:]]*(\*\*/)?\.env[[:space:]]*(#.*)?$' "$ROOT/.dockerignore"; then
	echo "Aviso: .dockerignore no excluye .env. Un .env del contexto podría entrar en la imagen." >&2
fi

if ss -H -ltn | awk '{print $4}' | grep -Eq '(^|[^0-9])5001$'; then
	die "el puerto 5001 está ocupado en este host. Libéralo antes de simular el build de CI."
fi

pass "preflight"

cache_args=()
if [[ "$NO_CACHE" -eq 1 ]]; then
	cache_args+=(--no-cache)
	echo "Build sin caché de capas."
fi

echo "Construyendo qrcodly-backend:ci (linux/amd64)..."
backend_started=$SECONDS
if ! docker buildx build --load --platform linux/amd64 \
	"${cache_args[@]}" \
	-t qrcodly-backend:ci \
	-f apps/backend/Dockerfile \
	.; then
	fail "build del backend"
	finish
fi
pass "build del backend ($((SECONDS - backend_started))s)"

echo "Levantando el stack efímero..."
if ! docker compose -f "$COMPOSE_FILE" up -d --wait; then
	echo "FALLO: el stack efímero no quedó sano." >&2
	docker compose -f "$COMPOSE_FILE" ps -a >&2 || true
	docker compose -f "$COMPOSE_FILE" logs --tail 60 migrate backend >&2 || true
	fail "stack efímero"
	finish
fi
pass "stack efímero"

openapi_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$OPENAPI_URL" || true)"
if [[ "$openapi_code" != "200" ]]; then
	fail "GET ${OPENAPI_URL} devolvió ${openapi_code:-sin respuesta}"
	finish
fi
pass "GET /api/v1/openapi.json"

echo "Construyendo qrcodly-frontend:ci (linux/amd64)..."
frontend_build_args=()
for key in "${FRONTEND_BUILD_ARG_KEYS[@]}"; do
	if [[ -n "${BUILD_ARGS[$key]:-}" ]]; then
		frontend_build_args+=(--build-arg "${key}=${BUILD_ARGS[$key]}")
	fi
done
frontend_build_args+=(--build-arg "OPENAPI_URL=${OPENAPI_URL}")

frontend_started=$SECONDS
if ! docker buildx build --load --platform linux/amd64 --network host \
	"${cache_args[@]}" \
	-t qrcodly-frontend:ci \
	-f apps/frontend/Dockerfile \
	"${frontend_build_args[@]}" \
	.; then
	fail "build del frontend"
	finish
fi
pass "build del frontend ($((SECONDS - frontend_started))s)"

SMOKE_ENV_FILE="$(mktemp)"
chmod 600 "$SMOKE_ENV_FILE"
for key in "${FRONTEND_BUILD_ARG_KEYS[@]}"; do
	if [[ -n "${BUILD_ARGS[$key]:-}" ]]; then
		printf '%s=%s\n' "$key" "${BUILD_ARGS[$key]}" >>"$SMOKE_ENV_FILE"
	fi
done
cat >>"$SMOKE_ENV_FILE" <<'EOF'
AXIOM_TOKEN=ci-fake-axiom-token
AXIOM_DATASET=ci-fake
CLERK_SECRET_KEY=sk_test_ciFakeNotARealClerkSecretKey000
INTERNAL_API_SECRET=ci-internal-api-secret-not-real-32b
EOF

docker rm -f "$FRONTEND_SMOKE_NAME" >/dev/null 2>&1 || true
if ! docker run -d --name "$FRONTEND_SMOKE_NAME" \
	--read-only \
	--tmpfs /app/apps/frontend/.next/cache:uid=1000,gid=1000,mode=0755,size=512m \
	--tmpfs /app/apps/frontend/.next/server/route-cache:uid=1000,gid=1000,mode=0755,size=128m \
	--env-file "$SMOKE_ENV_FILE" \
	-p "127.0.0.1:${FRONTEND_SMOKE_PORT}:3000" \
	qrcodly-frontend:ci >/dev/null; then
	fail "arranque del contenedor de smoke del frontend"
	finish
fi

frontend_code=""
for _ in $(seq 1 45); do
	frontend_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${FRONTEND_SMOKE_PORT}/" || true)"
	if [[ "$frontend_code" == "200" ]]; then
		break
	fi
	sleep 2
done
if [[ "$frontend_code" == "200" ]]; then
	pass "frontend GET /"
else
	docker logs --tail 40 "$FRONTEND_SMOKE_NAME" >&2 || true
	fail "frontend GET / devolvió ${frontend_code:-sin respuesta}"
fi

backend_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:5001/api/v1" || true)"
if [[ "$backend_code" == "200" ]]; then
	pass "backend GET /api/v1"
else
	fail "backend GET /api/v1 devolvió ${backend_code:-sin respuesta}"
fi

check_user() {
	local image="$1"
	local user
	user="$(docker image inspect -f '{{.Config.User}}' "$image")"
	if [[ "$user" == "1000" ]]; then
		pass "User de ${image} es 1000"
	else
		fail "User de ${image} es '${user}', se esperaba 1000"
	fi
}

check_size() {
	local image="$1"
	local bytes mib
	bytes="$(docker image inspect -f '{{.Size}}' "$image")"
	mib=$(((bytes + 524288) / 1048576))
	pass "tamaño de ${image}: ${mib} MiB"
}

audit_image() {
	local image="$1"
	local cid paths classified env_bad map_bad map_build map_deps
	cid="$(docker create "$image")"
	paths="$(mktemp)"
	if ! docker export "$cid" | tar -t >"$paths"; then
		docker rm "$cid" >/dev/null 2>&1 || true
		rm -f "$paths"
		fail "no se pudieron listar los ficheros de ${image}"
		return
	fi
	docker rm "$cid" >/dev/null

	classified="$(mktemp)"
	awk '
		{
			path = $0
			sub(/^\.\//, "", path)
			n = split(path, parts, "/")
			base = parts[n]
			sub(/\/$/, "", base)
			if (base ~ /^\.env(\..*)?$/) {
				if (path ~ /\/node_modules\// && (base == ".env.example" || base == ".env.sample")) next
				print "ENV\t" path
			}
			if (base ~ /\.map$/) {
				if (path ~ /\/node_modules\//) {
					print "DEP"
				} else if (path ~ /\/apps\/backend\/build\// || path ~ /\/packages\/shared\/dist\// || path ~ /\/packages\/db\/dist\// || path ~ /\/apps\/frontend\/\.next\//) {
					print "BUILD"
				} else {
					print "BAD\t" path
				}
			}
		}
	' "$paths" >"$classified"
	rm -f "$paths"

	env_bad=0
	map_bad=0
	map_build=0
	map_deps=0
	while IFS=$'\t' read -r kind rest; do
		case "$kind" in
		ENV)
			echo "  ${image}: ${rest}" >&2
			env_bad=1
			;;
		BAD)
			if [[ "$map_bad" -lt 20 ]]; then
				echo "  ${image}: ${rest}" >&2
			fi
			map_bad=$((map_bad + 1))
			;;
		BUILD) map_build=$((map_build + 1)) ;;
		DEP) map_deps=$((map_deps + 1)) ;;
		esac
	done <"$classified"
	rm -f "$classified"

	if [[ "$env_bad" -eq 0 ]]; then
		pass "sin .env* en ${image}"
	else
		fail "hay .env* en ${image}"
	fi
	if [[ "$map_bad" -eq 0 ]]; then
		pass "sin .map inesperados en ${image} (compilación ${map_build}, dependencias ${map_deps})"
	else
		fail "hay ${map_bad} .map inesperados en ${image}"
	fi
}

check_user qrcodly-backend:ci
check_user qrcodly-frontend:ci
check_size qrcodly-backend:ci
check_size qrcodly-frontend:ci
audit_image qrcodly-backend:ci
audit_image qrcodly-frontend:ci

backend_cid="$(docker compose -f "$COMPOSE_FILE" ps -q backend)"
backend_env="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$backend_cid")"
node_env="$(printf '%s\n' "$backend_env" | sed -n 's/^NODE_ENV=//p' | head -n 1)"
tz="$(printf '%s\n' "$backend_env" | sed -n 's/^TZ=//p' | head -n 1)"
api_host="$(printf '%s\n' "$backend_env" | sed -n 's/^API_HOST=//p' | head -n 1)"
if [[ "$node_env" == "production" && "$tz" == "Europe/Berlin" && "$api_host" == "0.0.0.0" ]]; then
	pass "backend NODE_ENV=production TZ=Europe/Berlin API_HOST=0.0.0.0"
else
	fail "backend NODE_ENV='${node_env}' TZ='${tz}' API_HOST='${api_host}'"
fi

migrate_cid="$(docker compose -f "$COMPOSE_FILE" ps -aq migrate)"
migrate_state="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$migrate_cid")"
if [[ "$migrate_state" == "exited 0" ]]; then
	pass "migrate terminó con exit 0"
else
	fail "migrate terminó en '${migrate_state}'"
fi

finish
