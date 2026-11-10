# Imágenes Docker

## Simular el build de CI en local

`scripts/docker/simulate-ci.sh` construye el backend y el frontend en `linux/amd64` y los prueba contra un stack que solo vive durante la ejecución. No reproduce los runners de GitHub ni la caché `gha`.

El stack está en `docker-compose.ci.yaml`: MySQL 8.4, Redis, MinIO (`pgsty/silo` y `pgsty/mc`, los mismos que producción), un contenedor que aplica las migraciones y el API. Las imágenes de soporte, los healthchecks, `read_only`, el `tmpfs` de `/tmp` y el usuario de la imagen salen de `docker-compose.prod.yaml`. No hay `restart`. El API solo se publica en `127.0.0.1:5001`. Los volúmenes se llaman dentro del proyecto `qrcodly-ci` y `down -v` no toca los de producción.

Los valores de ejecución del API están en `scripts/docker/ci.env`. Son falsos y solo tienen que pasar el esquema de `apps/backend/src/core/config/env.ts`. `CRON_ENABLED=false` para que los cron no llamen a Stripe, Clerk, Cloudflare ni Umami. Al registrar las rutas el proceso igual construye los clientes de Clerk y de Stripe, así que las claves tienen la forma que esas librerías aceptan al arrancar y nada más: `CLERK_PUBLISHABLE_KEY` es `pk_test_` más el base64 de `clerk.example.com$`, y `CLERK_SECRET_KEY` y `STRIPE_SECRET_KEY` empiezan por `sk_test_`. `SENTRY_DSN` es una URL que el SDK puede parsear (`https://ci@sentry.invalid/1`) y `UMAMI_HOST` es `https://umami.example.com`. `JWT_SECRET` y `COOKIE_SECRET` tienen 32 caracteres o más. `ANALYTICS_ENCRYPTION_KEY` son 64 hexadecimales. No salen de `.env` ni de `.env.production`.

Desde la raíz del repositorio:

```bash
./scripts/docker/simulate-ci.sh
```

Por defecto los build args del frontend se leen de `.env.production`. Estas nueve claves tienen que estar y no pueden ir vacías (las mismas que comprueba `.github/workflows/container.yml`):

- `NEXT_PUBLIC_FRONTEND_URL`
- `NEXT_PUBLIC_API_URL`
- `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY`
- `NEXT_PUBLIC_SENTRY_DSN`
- `NEXT_PUBLIC_GOOGLE_API_KEY`
- `NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_MONTHLY`
- `NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_ANNUAL`
- `NEXT_PUBLIC_STRIPE_ADDON_DOMAIN_PRICE_ID_MONTHLY`
- `NEXT_PUBLIC_STRIPE_ADDON_DOMAIN_PRICE_ID_ANNUAL`

Next las hornea en el bundle. Si en ese fichero aparece una clave `*_SECRET` o `*_PASSWORD`, el script avisa y no la pasa al build. Si `.dockerignore` no excluye `.env`, también avisa.

```bash
./scripts/docker/simulate-ci.sh --build-args-file ruta/al/fichero
./scripts/docker/simulate-ci.sh --keep
./scripts/docker/simulate-ci.sh --no-cache
```

`--keep` deja el stack y el contenedor de smoke del frontend en marcha. Sin esa opción, al salir (también si falla) el script ejecuta `docker compose -f docker-compose.ci.yaml down -v` y borra el contenedor suelto.

`--no-cache` pasa `--no-cache` a los dos `docker buildx build`. Sin esa opción, BuildKit reutiliza las capas ya construidas y el script las da por válidas: borrar `qrcodly-backend:ci` o `qrcodly-frontend:ci` no vacía esa caché. El almacén de pnpm que el Dockerfile monta con `--mount=type=cache` se conserva; para vaciarlo también, `docker builder prune`.

Hace falta Docker, el plugin buildx y el daemon en marcha. El puerto 5001 tiene que estar libre. El frontend se construye con `--network host` y `OPENAPI_URL=http://127.0.0.1:5001/api/v1/openapi.json`, así que el spec sale del API efímero y no de producción.

El smoke test arranca el frontend en solo lectura, con los mismos tmpfs que el compose de producción, y publica el puerto 3000 del contenedor en `127.0.0.1:33173` para no pisar un Next que ya esté en el 3000. Comprueba `GET /` y `GET /api/v1` (los dos tienen que responder 200), que el `User` de cada imagen sea `1000`, el tamaño de cada imagen, que no haya `.env*` ni source maps fuera de `node_modules` y de la salida de compilación, que el backend en ejecución tenga `NODE_ENV=production`, `TZ=Europe/Berlin` y `API_HOST=0.0.0.0`, y que `migrate` haya salido con código 0. El resumen final marca OK o FALLO. El script termina en un código distinto de 0 si algo falla.

## Publicar en GHCR

`.github/workflows/docker-publish.yml` construye y publica `qrcodly-backend` y `qrcodly-frontend` en GitHub Container Registry. No publica `qrcodly-mcp-server`. La plataforma es solo `linux/amd64`.

Se dispara con un push a `main`, con un push de un tag `v*` y con una ejecución manual. El filtro de rutas es el de `.github/workflows/container.yml` (`**.md`, `docs/`, `load-tests/`, `apps/desktop/`, `apps/browser-extension/`, `apps/integrations/`). Va en el evento `push`, así que también se aplica a los tags.

El nombre de cada imagen lo genera `docker/metadata-action`, en minúsculas, sin owner fijo: `ghcr.io/<owner>/qrcodly-backend` y `ghcr.io/<owner>/qrcodly-frontend`. En este fork quedan en `ghcr.io/ario-weareadn/qrcodly-backend` y `ghcr.io/ario-weareadn/qrcodly-frontend`. Las dos llevan la etiqueta `org.opencontainers.image.source` apuntando al repositorio (`https://github.com/<owner>/<repo>`).

Antes de construir el frontend, el workflow levanta `docker-compose.ci.yaml` para que el API responda en `127.0.0.1:5001` y el build pueda leer `OPENAPI_URL=http://127.0.0.1:5001/api/v1/openapi.json`. Si ese arranque falla, el job falla y el log del contenedor `backend` queda en el resumen. Al salir, también si falla un paso posterior, ejecuta `docker compose -f docker-compose.ci.yaml down -v`.

### Variables de Actions

Hace falta una variable del repositorio, no un secreto nuevo. El login en `ghcr.io` usa el `GITHUB_TOKEN` del job. No se lee `.env` ni `.env.production`.

En Settings → Secrets and variables → Actions → Variables, `FRONTEND_BUILD_ARGS` (la misma que usa `container.yml` para producción) va con una clave por línea, `CLAVE=valor`. Tiene que existir antes de compilar. Si falta una de estas nueve o el valor va vacío, el job para con `::error::` y no construye ninguna imagen:

- `NEXT_PUBLIC_FRONTEND_URL`
- `NEXT_PUBLIC_API_URL`
- `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY`
- `NEXT_PUBLIC_SENTRY_DSN`
- `NEXT_PUBLIC_GOOGLE_API_KEY`
- `NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_MONTHLY`
- `NEXT_PUBLIC_STRIPE_PRO_PRICE_ID_ANNUAL`
- `NEXT_PUBLIC_STRIPE_ADDON_DOMAIN_PRICE_ID_MONTHLY`
- `NEXT_PUBLIC_STRIPE_ADDON_DOMAIN_PRICE_ID_ANNUAL`

La variable es de este repositorio. Un fork no hereda la del upstream. `OPENAPI_URL` no forma parte de la variable: el workflow lo fija al API efímero.

### Visibilidad del paquete

El primer push crea `qrcodly-backend` y `qrcodly-frontend` como paquetes privados. Hay que poner cada uno en público una sola vez: en la ficha del paquete, Package settings → Change package visibility → Public, y confirmar escribiendo el nombre del paquete. Los pushes siguientes no cambian esa visibilidad. Mientras sigan privados, un `docker pull` sin sesión en GHCR no puede bajarlos.

### Esquema de tags

El sha corto tiene exactamente 7 caracteres hexadecimales. `workflow_dispatch` publica solo ese sha, también cuando se lanza desde `main`.

| Evento | Tags |
| --- | --- |
| Push a `main` | `latest` y el sha de 7 caracteres |
| Push de un tag `v*` | el tag git (`vX.Y.Z`) y `latest` |
| Ejecución manual (`workflow_dispatch`), desde cualquier rama, incluida `main` | solo el sha de 7 caracteres |

### Relanzar a mano

En Actions → Publish Docker images → Run workflow, elige la rama y lanza el workflow. Eso es `workflow_dispatch`: publica solo `:<sha7>` de ese commit.

Re-run jobs sobre una ejecución ya hecha repite el evento original. Un re-run de un push a `main` vuelve a publicar `latest` y el sha; un re-run de un tag `v*` vuelve a publicar ese tag y `latest`.

## Desplegar desde GHCR

`docker-compose.prod.yaml` es el único compose que consume estas imágenes. `migrate` y `backend` usan `ghcr.io/ario-weareadn/qrcodly-backend`. `frontend` usa `ghcr.io/ario-weareadn/qrcodly-frontend`. Las dos son `linux/amd64`. El compose de desarrollo no las referencia.

El tag lo marca `QRCODLY_TAG` en `.env.production`. Vacío o ausente significa `latest`.

Desde la raíz del repositorio, en el servidor:

```bash
docker compose -f docker-compose.prod.yaml pull && docker compose -f docker-compose.prod.yaml up -d --wait
```

`pull` descarga el tag elegido. `up -d --wait` recrea lo que haya cambiado y espera a los healthchecks. `migrate` usa la misma imagen y el mismo tag que `backend`, así que el esquema y el API van juntos.

Para no repetir `-f`:

```bash
export COMPOSE_FILE=docker-compose.prod.yaml
```

O la misma asignación dentro de `.env.production` (`COMPOSE_FILE=docker-compose.prod.yaml`). Compose lee `COMPOSE_FILE` del entorno del proceso. Si la variable está en `.env.production`, hay que cargar ese fichero con `--env-file .env.production`: el `env_file` de cada servicio mete variables en el contenedor y no elige el fichero de compose ni interpola el YAML. Las claves `${...}` (contraseñas, `QRCODLY_TAG`) salen de ahí. Con `COMPOSE_FILE` ya visible:

```bash
docker compose --env-file .env.production pull && docker compose --env-file .env.production up -d --wait
```

Si `COMPOSE_FILE` no está definido, conserva `-f docker-compose.prod.yaml` junto a `--env-file .env.production`.

Hasta que el workflow haya publicado los paquetes, `pull` no tiene imagen que bajar. La visibilidad (público, o sesión en GHCR) está en «Visibilidad del paquete».

### Fijar una versión

En `.env.production`:

```bash
QRCODLY_TAG=a1b2c3d
```

`a1b2c3d` es el sha de 7 caracteres que publicó el workflow (ver «Esquema de tags»). Un tag git `vX.Y.Z` también vale cuando ese push ya publicó la imagen. Después, el mismo `pull` y `up -d --wait`.

`latest` se mueve con cada push a `main` y con cada tag `v*`. No fija una publicación.

### Rollback a un sha anterior

Escribe el `<sha7>` de una publicación ya hecha en `QRCODLY_TAG` y vuelve a ejecutar el `pull` y el `up -d --wait`. Esa etiqueta sigue en GHCR; el servidor no compila nada. `migrate` corre con esa misma imagen. Si el esquema de ese sha no encaja con los datos actuales, `migrate` no termina bien y el backend no arranca.

Para volver al tag móvil, deja `QRCODLY_TAG` vacío o quita la línea y repite el arranque. Eso vuelve a pedir `latest`.

### Cambiar una NEXT_PUBLIC_*

Esas variables se hornean al publicar la imagen. Viven en la variable de Actions `FRONTEND_BUILD_ARGS`, no en el servidor. Cambiar una obliga a editar esa variable y a relanzar el workflow: un push a `main`, un tag `v*`, o Actions → Publish Docker images → Run workflow. Cuando la imagen nueva esté en GHCR, el servidor hace `pull` y `up -d --wait`. Editar `.env.production` no cambia el bundle.

`OPENAPI_URL` no forma parte de `FRONTEND_BUILD_ARGS`. El workflow lo fija al API efímero de `docker-compose.ci.yaml`.

## Validación manual

`scripts/docker/verify-prod.sh` comprueba, en cualquier máquina con Docker (también el servidor de Plesk), que una imagen ya publicada arranca con `docker-compose.prod.yaml`. No compila. Cada comprobación sale como OK o FALLO, con una pista de cómo arreglarla. El aviso de puertos no cambia el código de salida. Sin `--down` el script no tira la pila, ni siquiera desde el `trap`.

**Antes de desplegar (en GitHub):**

- El workflow Publish Docker images terminó en verde.
- En la pestaña Packages aparecen los tags `:latest` y `:<sha7>`.
- El paquete está en público.
- La variable `FRONTEND_BUILD_ARGS` está definida.

**En el servidor:**

Desde la raíz del repositorio:

```bash
export COMPOSE_FILE=docker-compose.prod.yaml
./scripts/docker/verify-prod.sh
```

`--tag` elige la etiqueta (por defecto `latest`). `--env-file` es el fichero que interpola el YAML (por defecto `.env.production`), no solo el `env_file` de cada servicio. `--down` ejecuta `docker compose down` al terminar.

Después, a mano, lo que el script no cubre:

- Abrir `https://qr.weareadn.dev`.
- Iniciar sesión con Clerk.
- Crear un QR.
- Descargar el PNG.
- En la consola de Sentry, comprobar que no llegan errores nuevos.

**Rollback:**

Con `COMPOSE_FILE` exportado:

```bash
QRCODLY_TAG=<sha7 anterior> docker compose up -d
./scripts/docker/verify-prod.sh --tag <sha7 anterior>
```

Si las claves `${...}` salen de `.env.production`, el `up` lleva `--env-file .env.production`, igual que en «Desplegar desde GHCR».

### Síntomas frecuentes

| Síntoma | Causa |
| --- | --- |
| `manifest unknown` | El tag no existe en GHCR. |
| `denied` | El paquete sigue privado. |
| El frontend llama a una URL de API equivocada | Los build args están mal (`FRONTEND_BUILD_ARGS`). Hay que relanzar el workflow. |
| `unhealthy` en `backend` | Falta una variable de runtime. |
