# Por qué QRcodly pesa en Docker

Medido el 10 de noviembre de 2026 en esta máquina, con las imágenes ya construidas
`qrcodly-backend:prod` (hace 6 días) y `qrcodly-frontend:prod` (hace 21 horas).
El stack de producción no estaba arrancado: se levantó una copia de usar y tirar,
con secretos falsos y sin tocar los volúmenes `qrcodly_db` ni `qrcodly_minio`.
El servidor de Plesk no se ha medido.

## Respuesta corta

Generar un QR no se come 4 GB. En la imagen del API, un proceso que importa
JSDOM, `qr-code-styling`, `@resvg/resvg-js` y `sharp`, y produce SVG, PNG, WebP
y JPEG, se queda en **152 MiB** de RAM. El PNG de 512 px pesa **2,2 KB**.

Next tampoco es el grueso. Tras servir la home (HTTP 200, 323 KB de HTML) el
contenedor del frontend usa **243 MiB**.

El stack de producción entero, en reposo y después de esa petición, suma
**unos 1,2 GiB** de RAM. El proceso más grande es MySQL.

## RAM del stack de producción

Misma configuración que `docker-compose.prod.yaml`: MySQL 8.4 con
`innodb-buffer-pool-size=512M` e `innodb-redo-log-capacity=256M`, Redis 7
Alpine, MinIO (`pgsty/silo`) y las dos imágenes de la app.

| Contenedor | RAM (`docker stats`) | Qué es |
| --- | ---: | --- |
| MySQL 8.4 | 459 MiB | El buffer pool de 512M se reserva al arrancar, haya QR o no |
| API (`node build/src/index.js`) | 386 MiB | Fastify, Clerk, Sentry, OpenTelemetry, Sharp, Drizzle. Aún no ha pintado un QR |
| Frontend (`node server.js`) | 243 MiB | Next 16 en modo standalone, después de la home |
| MinIO | 111 MiB | Almacén de objetos |
| Redis | 4 MiB | Caché |
| **Suma** | **~1,2 GiB** | |

Antes de la home, Next estaba en 145 MiB. El salto hasta 243 MiB es el render
de una página, no el generador de QR. El preview del generador se dibuja en el
canvas del navegador de quien lo usa (`apps/frontend/src/components/qr-generator/QrCode.tsx`
es un componente de cliente).

Los `tmpfs` del compose (512 MiB en `/tmp` del API, 512 MiB de caché de Next y
128 MiB de `route-cache`) son un techo, no memoria ya ocupada. En esta medición
estaban vacíos y no salen en la suma.

## Qué cuesta generar un QR

El API no lanza Chromium ni Playwright. El dibujo es este camino, en el mismo
proceso Node:

1. `qr-code-styling` calcula el SVG. El DOM lo pone JSDOM
   (`apps/backend/src/modules/qr-code/lib/styled-qr-code/index.ts`).
2. Si el formato no es SVG, `@resvg/resvg-js` lo rasteriza a PNG
   (`render-qr-code.use-case.ts`).
3. `sharp` (libvips) solo entra para WebP, JPEG o para escribir los DPI de un PNG
   de impresión.

RSS del proceso de prueba, paso a paso:

| Paso | RSS |
| --- | ---: |
| Node recién arrancado | 44 MiB |
| Import de JSDOM | 115 MiB |
| `qr-code-styling` | 115 MiB |
| resvg | 120 MiB |
| sharp | 138 MiB |
| SVG + PNG + WebP + JPEG ya generados | 152 MiB |

Tamaños de esa salida: SVG 38 KB, PNG 2,2 KB, WebP 0,5 KB, JPEG 1,8 KB.

JSDOM es lo que más sube la cifra dentro del generador (+71 MiB al importarlo).
Sigue siendo una fracción del API, que ya ocupa 386 MiB con todo el servidor
cargado.

## Disco

El checkout, sin `node_modules` ni `.next`, pesa **15 MB** (`apps/` 13 MB).
El volumen está en las imágenes.

Tamaños que imprime `docker images` (cada imagen incluye la base de Node, así
que la suma cuenta dos veces los ~328 MB compartidos por API y frontend):

| Imagen | Tamaño que lista Docker | De qué es la parte propia |
| --- | ---: | --- |
| `mysql:8.4` | 1,11 GB | La imagen más grande del stack. No es código de QRcodly |
| `qrcodly-backend:prod` | 669 MB | Base Node ~331 MB + `node_modules` de producción 266 MB + build 7 MB |
| `qrcodly-frontend:prod` | 535 MB | La misma base Node + standalone 84 MB + estáticos 70 MB |
| `pgsty/silo` (MinIO) | 221 MB | |
| `pgsty/mc` | 76 MB | Solo el alta del bucket, se apaga |
| `redis:7-alpine` | 59 MB | |

Suma de lo que lista Docker, sin desduplicar: **~2,6 GB** de imágenes.
El volumen `qrcodly_db` ocupa otros **371 MB**. Juntos rondan los **3 GB** de
disco de este proyecto. Redis y MinIO en volumen son kilobytes.

Dentro del frontend, `.next/static` son 68 MB y **46 MB son source maps**
(556 ficheros). Salen de `productionBrowserSourceMaps: true` en
`apps/frontend/next.config.mjs`. Engordan la imagen y lo que descarga el
navegador. No explican ni la RAM ni los 4 GB.

Dentro del API, los paquetes más grandes del `node_modules` de producción son
de plataforma, no del QR:

| Grupo | Disco aproximado |
| --- | ---: |
| Sentry | ~46 MB |
| OpenTelemetry (muchos paquetes pequeños) | ~35 MB |
| Stripe | 19 MB |
| libvips (`sharp`) | 18 MB |
| Drizzle | 17 MB |
| JSDOM | 4,4 MB |
| resvg | 4,2 MB |

## De dónde puede salir un 4 GB

En esta medición no hay un contenedor, ni la suma de ellos, en 4 GB de RAM.
1,2 GiB es lo que el stack usa estando vivo.

La cifra encaja mejor con el disco, redondeada: imágenes (~2,6 GB, con la base
de Node contada dos veces) más el volumen de MySQL (371 MB) se acercan a 3 GB.
La caché de build de Docker en esta máquina es de **10,1 GB**, pero mezcla
QRcodly con Sail, n8n y el resto de proyectos. No es peso de este repo.

En el compose de desarrollo (`docker-compose.yaml`) phpMyAdmin y Umami quedan
fuera del arranque normal (perfiles `tools` y `analytics`). Esas imágenes no
están en esta máquina y no se han medido.

## Qué mueve el número, si más adelante se quiere adelgazar

- RAM: los dos compose arrancan MySQL con buffer de 128M, redo de 64M,
  `max-connections=100` y `performance-schema=OFF`. La medición de arriba es
  anterior, con el buffer de 512M. Hay que recrear el contenedor para que
  coja los valores nuevos.
- Disco del frontend: quitar `productionBrowserSourceMaps` recorta unos 46 MB
  de la imagen y de los estáticos.
- Disco del API: Sentry, OpenTelemetry y Stripe son la mayor parte del
  `node_modules`. El generador (JSDOM, resvg, sharp) son unos 27 MB.
- El render del QR, en sí, no tiene un recorte que se note al lado de MySQL.
